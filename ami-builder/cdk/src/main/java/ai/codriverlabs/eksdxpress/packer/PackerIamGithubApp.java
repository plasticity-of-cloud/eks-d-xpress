package ai.codriverlabs.eksdxpress.packer;

import software.amazon.awscdk.App;
import software.amazon.awscdk.Environment;
import software.amazon.awscdk.StackProps;

public class PackerIamGithubApp {
    public static void main(String[] args) {
        var app = new App();

        new EksDXpressPackerIamStack(app, "EksDXpressPackerIamGithubStack", StackProps.builder()
                .env(Environment.builder()
                        .account(System.getenv("CDK_DEFAULT_ACCOUNT"))
                        .region(System.getenv("CDK_DEFAULT_REGION"))
                        .build())
                .build());

        app.synth();
    }
}
