package io.github.shrubberer.istiofailoverdemo;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.http.HttpStatusCode;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final AppProperties appProperties;

    public HelloController(AppProperties appProperties) {
        this.appProperties = appProperties;
    }

    @GetMapping("/")
    public ResponseEntity<String> hello(@RequestParam(name = "input", required = false) String input) {
        if (shouldTriggerFault(input)) {
            String body = String.format(
                "%s forced HTTP %d for input '%s'",
                appProperties.getInstanceName(),
                appProperties.getFault().getStatusCode(),
                input
            );
            return withInstanceHeaders(
                ResponseEntity.status(HttpStatusCode.valueOf(appProperties.getFault().getStatusCode()))
            ).body(body);
        }

        return withInstanceHeaders(ResponseEntity.ok()).body(appProperties.getReplyMessage());
    }

    @GetMapping("/details")
    public Map<String, Object> details() {
        Map<String, Object> details = new LinkedHashMap<>();
        details.put("instanceName", appProperties.getInstanceName());
        details.put("replyMessage", appProperties.getReplyMessage());
        details.put("version", appProperties.getVersion());
        details.put("faultEnabled", appProperties.getFault().isEnabled());
        details.put("faultTriggerInput", appProperties.getFault().getTriggerInput());
        details.put("faultStatusCode", appProperties.getFault().getStatusCode());
        return details;
    }

    private boolean shouldTriggerFault(String input) {
        return appProperties.getFault().isEnabled()
            && input != null
            && input.equals(appProperties.getFault().getTriggerInput());
    }

    private ResponseEntity.BodyBuilder withInstanceHeaders(ResponseEntity.BodyBuilder bodyBuilder) {
        return bodyBuilder
            .header("X-Failover-Instance", appProperties.getInstanceName())
            .header("X-Failover-Version", appProperties.getVersion());
    }
}
