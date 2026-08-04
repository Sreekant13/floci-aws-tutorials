/**
 * The same order pipeline as ../python/messaging_demo.py, using AWS SDK v3.
 *
 *   npm install
 *   node messaging-demo.mjs
 */

import {
  SQSClient,
  CreateQueueCommand,
  GetQueueAttributesCommand,
  SendMessageCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  DeleteQueueCommand,
} from "@aws-sdk/client-sqs";
import {
  SNSClient,
  CreateTopicCommand,
  SubscribeCommand,
  SetSubscriptionAttributesCommand,
  PublishCommand,
  DeleteTopicCommand,
} from "@aws-sdk/client-sns";

// ---------------------------------------------------------------------------
// The ONLY Floci-specific lines. Drop `endpoint` and this runs on real AWS.
// ---------------------------------------------------------------------------
const config = {
  endpoint: process.env.AWS_ENDPOINT_URL ?? "http://localhost:4566",
  region: process.env.AWS_DEFAULT_REGION ?? "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID ?? "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY ?? "test",
  },
};

const sqs = new SQSClient(config);
const sns = new SNSClient(config);

const SUFFIX = "demo-node";
const step = (msg) => console.log(`\n==> ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function makeQueue(QueueName, Attributes = {}) {
  const { QueueUrl } = await sqs.send(new CreateQueueCommand({ QueueName, Attributes }));
  const { Attributes: a } = await sqs.send(
    new GetQueueAttributesCommand({ QueueUrl, AttributeNames: ["QueueArn"] })
  );
  return { url: QueueUrl, arn: a.QueueArn };
}

async function drain(QueueUrl, label, WaitTimeSeconds = 5) {
  const { Messages = [] } = await sqs.send(
    new ReceiveMessageCommand({ QueueUrl, MaxNumberOfMessages: 10, WaitTimeSeconds })
  );
  for (const m of Messages) {
    console.log(`    ${label}: ${m.Body.slice(0, 80)}`);
    // Deleting is a separate call. Receiving only hid the message.
    await sqs.send(new DeleteMessageCommand({ QueueUrl, ReceiptHandle: m.ReceiptHandle }));
  }
  if (Messages.length === 0) console.log(`    ${label}: nothing`);
  return Messages;
}

async function main() {
  step("Creating queues and topic");
  const email = await makeQueue(`email-queue-${SUFFIX}`);
  const fraud = await makeQueue(`fraud-queue-${SUFFIX}`);
  const { TopicArn } = await sns.send(new CreateTopicCommand({ Name: `orders-${SUFFIX}` }));
  console.log(`    topic: ${TopicArn}`);

  step("Subscribing both queues to the topic");
  const emailSub = (
    await sns.send(new SubscribeCommand({ TopicArn, Protocol: "sqs", Endpoint: email.arn }))
  ).SubscriptionArn;
  const fraudSub = (
    await sns.send(new SubscribeCommand({ TopicArn, Protocol: "sqs", Endpoint: fraud.arn }))
  ).SubscriptionArn;

  // Raw delivery removes the SNS envelope. It is a property of the
  // subscription, so each subscriber chooses independently.
  for (const SubscriptionArn of [emailSub, fraudSub]) {
    await sns.send(
      new SetSubscriptionAttributesCommand({
        SubscriptionArn,
        AttributeName: "RawMessageDelivery",
        AttributeValue: "true",
      })
    );
  }

  // The fraud queue only wants high value orders. SNS applies this before
  // delivery, so the fraud worker never even sees the others.
  await sns.send(
    new SetSubscriptionAttributesCommand({
      SubscriptionArn: fraudSub,
      AttributeName: "FilterPolicy",
      AttributeValue: JSON.stringify({ value: ["high"] }),
    })
  );
  console.log("    fraud queue filters on value=high");
  await sleep(1000);

  step("Publishing two orders, one high value and one low");
  for (const [Message, value] of [
    ["big order", "high"],
    ["small order", "low"],
  ]) {
    await sns.send(
      new PublishCommand({
        TopicArn,
        Message,
        MessageAttributes: { value: { DataType: "String", StringValue: value } },
      })
    );
  }
  await sleep(4000);

  step("What each queue actually received");
  await drain(email.url, "email");
  await drain(fraud.url, "fraud");

  step("Dead letter queue: parking a message that never succeeds");
  const dlq = await makeQueue(`orders-dlq-${SUFFIX}`);
  const main_ = await makeQueue(`orders-main-${SUFFIX}`, {
    RedrivePolicy: JSON.stringify({
      deadLetterTargetArn: dlq.arn,
      maxReceiveCount: "2",
    }),
    VisibilityTimeout: "1",
  });
  await sqs.send(new SendMessageCommand({ QueueUrl: main_.url, MessageBody: "poison" }));

  // Receive it repeatedly without ever deleting it, exactly as a failing
  // worker would. After maxReceiveCount attempts SQS moves it aside.
  for (let attempt = 1; attempt <= 3; attempt++) {
    const { Messages = [] } = await sqs.send(
      new ReceiveMessageCommand({ QueueUrl: main_.url })
    );
    console.log(`    attempt ${attempt}: ${Messages.length ? "received" : "nothing visible"}`);
    await sleep(2000);
  }

  const { Attributes } = await sqs.send(
    new GetQueueAttributesCommand({
      QueueUrl: dlq.url,
      AttributeNames: ["ApproximateNumberOfMessages"],
    })
  );
  console.log(`    messages now in the dead letter queue: ${Attributes.ApproximateNumberOfMessages}`);

  step("Cleaning up");
  for (const QueueUrl of [email.url, fraud.url, dlq.url, main_.url]) {
    await sqs.send(new DeleteQueueCommand({ QueueUrl }));
  }
  await sns.send(new DeleteTopicCommand({ TopicArn }));
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
