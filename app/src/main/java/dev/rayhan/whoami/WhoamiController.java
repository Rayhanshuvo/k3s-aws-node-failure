package dev.rayhan.whoami;

import jakarta.servlet.http.HttpServletRequest;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Every response says which pod and which node answered.
 * The load tester counts responses per node, so we can see where traffic goes
 * and what happens when one node disappears.
 *
 * POD_NAME, NODE_NAME and POD_IP are injected by Kubernetes (Downward API).
 */
@RestController
public class WhoamiController {

    @Value("${POD_NAME:local}")
    private String podName;

    @Value("${NODE_NAME:local}")
    private String nodeName;

    @Value("${POD_IP:127.0.0.1}")
    private String podIp;

    @Value("${app.version}")
    private String version;

    @GetMapping("/")
    public String home() {
        return "Hello from " + podName + " on " + nodeName + "\n";
    }

    /**
     * @param ms simulated work in milliseconds (default 20), so a request is "in flight"
     *           long enough to be affected when a node dies.
     */
    @GetMapping("/api/whoami")
    public Map<String, Object> whoami(@RequestParam(defaultValue = "20") long ms,
                                      HttpServletRequest request) throws InterruptedException {
        if (ms > 0) {
            Thread.sleep(Math.min(ms, 10_000));
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("pod", podName);
        body.put("node", nodeName);
        body.put("podIp", podIp);
        body.put("version", version);
        // With externalTrafficPolicy: Cluster this is usually a node IP (traffic was SNATed);
        // with Local it is the real client (here: the Nginx load balancer).
        body.put("seenClientIp", request.getRemoteAddr());
        return body;
    }
}
