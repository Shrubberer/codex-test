package io.github.shrubberer.istiofailoverdemo;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app")
public class AppProperties {

    private String instanceName = "primary";
    private String replyMessage = "hello from primary version 0.1.0";
    private String version = "0.1.0";
    private final Fault fault = new Fault();

    public String getInstanceName() {
        return instanceName;
    }

    public void setInstanceName(String instanceName) {
        this.instanceName = instanceName;
    }

    public String getReplyMessage() {
        return replyMessage;
    }

    public void setReplyMessage(String replyMessage) {
        this.replyMessage = replyMessage;
    }

    public String getVersion() {
        return version;
    }

    public void setVersion(String version) {
        this.version = version;
    }

    public Fault getFault() {
        return fault;
    }

    public static class Fault {

        private boolean enabled = true;
        private String triggerInput = "fail-primary";
        private int statusCode = 503;

        public boolean isEnabled() {
            return enabled;
        }

        public void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        public String getTriggerInput() {
            return triggerInput;
        }

        public void setTriggerInput(String triggerInput) {
            this.triggerInput = triggerInput;
        }

        public int getStatusCode() {
            return statusCode;
        }

        public void setStatusCode(int statusCode) {
            this.statusCode = statusCode;
        }
    }
}
