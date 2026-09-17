import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class Server {
    private static final String SERVICE_NAME = "java-app";

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8081"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

        server.createContext("/health", exchange -> respond(exchange,
                "{\"status\":\"ok\",\"service\":\"" + SERVICE_NAME + "\"}",
                "application/json"));

        server.createContext("/", exchange -> respond(exchange,
                "Hello from " + SERVICE_NAME + " (project-9 CD stack)\n",
                "text/plain"));

        server.setExecutor(null);
        server.start();
        System.out.println(SERVICE_NAME + " listening on :" + port);
    }

    private static void respond(HttpExchange exchange, String body, String contentType) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
