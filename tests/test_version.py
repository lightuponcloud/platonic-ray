import unittest
import json
import requests

from client_base import (
    TestClient,
    BASE_URL,
    USERNAME_1,
    PASSWORD_1,
    TEST_BUCKET_1,
    TEST_BUCKET_3,
    configure_boto3)
from light_client import LightClient


class VersionsTest(TestClient):

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.user_id = self.client.user_id
        self.token = self.client.token
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_download_db(self):
        result = self.client.get_version(TEST_BUCKET_1)
        self.assertEqual(result.status_code, 200)
        assert "DVV" in result.headers
        assert result.headers["DVV"]

    def test_download_tenant_db(self):
        result = self.client.get_version(TEST_BUCKET_3)
        self.assertEqual(result.status_code, 200)
        assert "DVV" in result.headers
        assert result.headers["DVV"]


if __name__ == "__main__":
    unittest.main()
