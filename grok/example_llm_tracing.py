import os
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from xai_sdk import Client
from xai_sdk.chat import user, system
from xai_sdk.telemetry import Telemetry

tracer_provider = TracerProvider(resource=Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "grok"),
}))
tracer_provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(
        endpoint=f"{os.getenv('CX_OTLP_ENDPOINT')}/v1/traces",
        headers={
            "Authorization": f"Bearer {os.getenv('CX_API_KEY')}",
            "cx-application-name": os.getenv("CX_APPLICATION_NAME", "grok"),
            "cx-subsystem-name": os.getenv("CX_SUBSYSTEM_NAME", "grok-api"),
        },
    )
))
trace.set_tracer_provider(tracer_provider)
Telemetry(provider=tracer_provider)

client = Client(api_key=os.getenv("XAI_API_KEY"), timeout=3600)
chat = client.chat.create(model="grok-3-mini")
chat.append(system("You are Grok, a helpful AI assistant."))
chat.append(user("Hello, what can you help me with?"))
response = chat.sample()
print(response.content)

tracer_provider.shutdown()
