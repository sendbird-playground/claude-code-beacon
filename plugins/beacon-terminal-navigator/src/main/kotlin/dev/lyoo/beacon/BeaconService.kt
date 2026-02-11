package dev.lyoo.beacon

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.startup.ProjectActivity
import com.intellij.openapi.wm.ToolWindowManager
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@Service(Service.Level.APP)
class BeaconService {
    private val log = Logger.getInstance(BeaconService::class.java)
    private var server: HttpServer? = null

    fun start() {
        if (server != null) return
        try {
            val addr = InetSocketAddress(InetAddress.getLoopbackAddress(), 19877)
            val srv = HttpServer.create(addr, 0)
            srv.createContext("/health") { ex -> respond(ex, 200, "ok") }
            srv.createContext("/focus-terminal") { ex -> handleFocusTerminal(ex) }
            srv.createContext("/active-terminal") { ex -> handleActiveTerminal(ex) }
            srv.executor = null
            srv.start()
            server = srv
            log.info("Beacon HTTP server listening on 127.0.0.1:19877")
        } catch (e: Exception) {
            log.warn("Failed to start Beacon HTTP server: ${e.message}")
        }
    }

    fun stop() {
        server?.stop(0)
        server = null
        log.info("Beacon HTTP server stopped")
    }

    private fun handleActiveTerminal(ex: HttpExchange) {
        if (ex.requestMethod != "GET") {
            respond(ex, 405, "method not allowed")
            return
        }
        try {
            val latch = CountDownLatch(1)
            var resultJson = ""

            ApplicationManager.getApplication().invokeLater {
                try {
                    val projects = ProjectManager.getInstance().openProjects
                    val entries = mutableListOf<String>()

                    for (project in projects) {
                        val tw = ToolWindowManager.getInstance(project).getToolWindow("Terminal") ?: continue
                        val cm = tw.contentManager
                        val selected = cm.selectedContent
                        if (selected != null) {
                            val projName = escapeJson(project.name)
                            val basePath = escapeJson(project.basePath ?: "")
                            val tabName = escapeJson(selected.displayName)
                            val allTabs = cm.contents.joinToString(",") { "\"${escapeJson(it.displayName)}\"" }
                            entries.add("""{"project":"$projName","basePath":"$basePath","tabName":"$tabName","tabs":[$allTabs]}""")
                        }
                    }

                    resultJson = "[${entries.joinToString(",")}]"
                } catch (e: Exception) {
                    log.warn("Error reading active terminal: ${e.message}")
                    resultJson = "[]"
                } finally {
                    latch.countDown()
                }
            }

            if (latch.await(3, TimeUnit.SECONDS)) {
                respondJson(ex, 200, resultJson)
            } else {
                respond(ex, 504, "timeout")
            }
        } catch (e: Exception) {
            log.warn("Error handling /active-terminal: ${e.message}")
            respond(ex, 500, "error: ${e.message}")
        }
    }

    private fun handleFocusTerminal(ex: HttpExchange) {
        if (ex.requestMethod != "POST") {
            respond(ex, 405, "method not allowed")
            return
        }
        try {
            val body = ex.requestBody.bufferedReader().readText()
            val projectName = extractJsonString(body, "project")
            val tabName = extractJsonString(body, "tabName")

            if (projectName.isNullOrEmpty() || tabName.isNullOrEmpty()) {
                respond(ex, 400, "missing project or tabName")
                return
            }

            // Find the matching project
            val project = ProjectManager.getInstance().openProjects.firstOrNull { p ->
                p.name == projectName || (p.basePath?.endsWith(projectName) == true)
            }

            if (project == null) {
                respond(ex, 404, "project not found")
                return
            }

            // Switch to the terminal tab on the EDT
            ApplicationManager.getApplication().invokeLater {
                val toolWindow = ToolWindowManager.getInstance(project).getToolWindow("Terminal")
                if (toolWindow == null) {
                    log.warn("Terminal tool window not found for project: $projectName")
                    return@invokeLater
                }
                toolWindow.show {
                    val cm = toolWindow.contentManager
                    val content = cm.contents.firstOrNull { c ->
                        c.displayName == tabName
                    }
                    if (content != null) {
                        cm.setSelectedContent(content)
                        log.info("Focused terminal tab '$tabName' in project '$projectName'")
                    } else {
                        log.warn("Terminal tab '$tabName' not found in project '$projectName'. " +
                                "Available: ${cm.contents.map { it.displayName }}")
                    }
                }
            }

            respond(ex, 200, "ok")
        } catch (e: Exception) {
            log.warn("Error handling /focus-terminal: ${e.message}")
            respond(ex, 500, "error: ${e.message}")
        }
    }

    private fun escapeJson(s: String): String {
        return s.replace("\\", "\\\\").replace("\"", "\\\"")
    }

    /** Simple JSON string value extractor — avoids dependency on org.json or gson. */
    private fun extractJsonString(json: String, key: String): String? {
        val pattern = """"$key"\s*:\s*"((?:[^"\\]|\\.)*)"""".toRegex()
        return pattern.find(json)?.groupValues?.get(1)
            ?.replace("\\\"", "\"")
            ?.replace("\\\\", "\\")
    }

    private fun respond(ex: HttpExchange, code: Int, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        ex.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
        ex.sendResponseHeaders(code, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }

    private fun respondJson(ex: HttpExchange, code: Int, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        ex.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
        ex.sendResponseHeaders(code, bytes.size.toLong())
        ex.responseBody.use { it.write(bytes) }
    }
}

class BeaconStartupActivity : ProjectActivity {
    override suspend fun execute(project: com.intellij.openapi.project.Project) {
        ApplicationManager.getApplication().getService(BeaconService::class.java)?.start()
    }
}
