package cloud.plasticity.eksdx.packer;

import software.amazon.awscdk.App;
import software.amazon.awscdk.Environment;
import software.amazon.awscdk.StackProps;

public class PackerIamApp {
    public static void main(String[] args) {
        var app = new App();

        new EksDXpressPackerIamStack(app, "EksDXpressPackerIamStack", StackProps.builder()
                .env(Environment.builder()
                        .account(System.getenv("CDK_DEFAULT_ACCOUNT"))
                        .region(System.getenv("CDK_DEFAULT_REGION"))
                        .build())
                .build());

        app.synth();
    }
}
