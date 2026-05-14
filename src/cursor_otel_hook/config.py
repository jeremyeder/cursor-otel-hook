"""Configuration management for Cursor OTEL Hook"""

import json
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


@dataclass
class OTELConfig:
    """OpenTelemetry configuration"""

    endpoint: str
    service_name: str
    insecure: bool = False
    headers: Optional[dict] = None
    mask_prompts: bool = True
    timeout: int = 30
    protocol: str = "http/protobuf"  # "grpc", "http/protobuf", or "http/json"

    @classmethod
    def from_env(cls) -> "OTELConfig":
        """Load configuration from environment variables"""
        protocol = os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf").lower()

        # Normalize protocol values - keep http/json and http/protobuf distinct
        if protocol == "http":
            protocol = "http/protobuf"  # Default HTTP to protobuf
        elif protocol not in ["grpc", "http/protobuf", "http/json"]:
            protocol = "grpc"  # Default to grpc for unknown values

        return cls(
            endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
            service_name=os.getenv("OTEL_SERVICE_NAME", "tailwind-cursor"),
            insecure=os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "true").lower() == "true",
            headers=cls._parse_headers(os.getenv("OTEL_EXPORTER_OTLP_HEADERS", "")),
            mask_prompts=os.getenv("CURSOR_OTEL_MASK_PROMPTS", "true").lower()
            == "true",
            timeout=int(os.getenv("OTEL_EXPORTER_OTLP_TIMEOUT", "30")),
            protocol=protocol,
        )

    @classmethod
    def from_file(cls, config_path: str) -> "OTELConfig":
        """Load configuration from JSON file using OTEL standard env var names"""
        import logging

        logger = logging.getLogger(__name__)

        path = Path(config_path)
        if not path.exists():
            raise FileNotFoundError(f"Config file not found: {config_path}")

        with open(path, "r") as f:
            data = json.load(f)

        logger.debug(f"Raw config file data: {data}")

        # Support standard OTEL environment variable names in JSON
        endpoint = data.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
        service_name = data.get("OTEL_SERVICE_NAME", "tailwind-cursor")
        protocol = data.get("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf").lower()
        insecure = (
            str(data.get("OTEL_EXPORTER_OTLP_INSECURE", "true")).lower() == "true"
        )
        headers = data.get("OTEL_EXPORTER_OTLP_HEADERS")
        mask_prompts = (
            str(data.get("CURSOR_OTEL_MASK_PROMPTS", "true")).lower() == "true"
        )
        timeout = int(data.get("OTEL_EXPORTER_OTLP_TIMEOUT", "30"))

        logger.debug(
            f"Parsed values - endpoint: {endpoint}, protocol: {protocol}, headers: {headers}"
        )

        # Parse headers if it's a string (same format as env var)
        if isinstance(headers, str):
            headers = cls._parse_headers(headers)

        # Normalize protocol values - keep http/json and http/protobuf distinct
        logger.debug(f"Protocol before normalization: '{protocol}'")
        if protocol == "http":
            protocol = "http/protobuf"  # Default HTTP to protobuf
            logger.debug("Normalized 'http' to 'http/protobuf'")
        elif protocol not in ["grpc", "http/protobuf", "http/json"]:
            logger.debug(f"Unknown protocol '{protocol}', defaulting to 'grpc'")
            protocol = "grpc"
        logger.debug(f"Protocol after normalization: '{protocol}'")

        return cls(
            endpoint=endpoint,
            service_name=service_name,
            insecure=insecure,
            headers=headers,
            mask_prompts=mask_prompts,
            timeout=timeout,
            protocol=protocol,
        )

    @classmethod
    def load(cls, config_file: Optional[str] = None) -> "OTELConfig":
        """
        Load configuration with precedence:
        1. Config file as base (if provided)
        2. Environment variables override individual fields
        """
        if config_file:
            try:
                config = cls.from_file(config_file)
            except FileNotFoundError:
                logger.warning(
                    f"Config file not found: {config_file}, falling back to environment variables"
                )
                config = cls.from_env()
            except Exception as e:
                logger.error(f"Error loading config file: {e}")
                raise
        else:
            config = cls.from_env()

        # Env vars override config file values when explicitly set
        cls._apply_env_overrides(config)

        if not cls._is_valid_endpoint(config.endpoint):
            logger.warning(f"Endpoint URL may be malformed: {config.endpoint}")

        logger.info(
            f"Configuration loaded: endpoint={config.endpoint}, "
            f"protocol={config.protocol}, service={config.service_name}"
        )
        logger.info(f"Auth headers configured: {bool(config.headers)}")

        return config

    @classmethod
    def _apply_env_overrides(cls, config: "OTELConfig") -> None:
        """Override config fields with env vars when explicitly set."""
        if "OTEL_EXPORTER_OTLP_ENDPOINT" in os.environ:
            config.endpoint = os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"]
            logger.info(f"Env override: endpoint={config.endpoint}")

        if "OTEL_SERVICE_NAME" in os.environ:
            config.service_name = os.environ["OTEL_SERVICE_NAME"]

        if "OTEL_EXPORTER_OTLP_PROTOCOL" in os.environ:
            config.protocol = os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"].lower()

        if "OTEL_EXPORTER_OTLP_INSECURE" in os.environ:
            config.insecure = os.environ["OTEL_EXPORTER_OTLP_INSECURE"].lower() == "true"

        if "CURSOR_OTEL_MASK_PROMPTS" in os.environ:
            config.mask_prompts = os.environ["CURSOR_OTEL_MASK_PROMPTS"].lower() == "true"

        if "OTEL_EXPORTER_OTLP_TIMEOUT" in os.environ:
            config.timeout = int(os.environ["OTEL_EXPORTER_OTLP_TIMEOUT"])

        # Headers: merge env var headers INTO config file headers
        if "OTEL_EXPORTER_OTLP_HEADERS" in os.environ:
            env_headers = cls._parse_headers(os.environ["OTEL_EXPORTER_OTLP_HEADERS"])
            if env_headers:
                if config.headers:
                    config.headers.update(env_headers)
                else:
                    config.headers = env_headers
                logger.info(f"Env override: merged headers {list(env_headers.keys())}")

    @staticmethod
    def _is_valid_endpoint(endpoint: str) -> bool:
        """Check if endpoint URL is well-formed (starts with http:// or https://)"""
        return endpoint.startswith("http://") or endpoint.startswith("https://")

    @staticmethod
    def _parse_headers(headers_str: str) -> Optional[dict]:
        """Parse OTEL headers from string format: key1=value1,key2=value2"""
        if not headers_str:
            return None

        headers = {}
        for pair in headers_str.split(","):
            if "=" in pair:
                key, value = pair.split("=", 1)
                headers[key.strip()] = value.strip()

        return headers if headers else None
