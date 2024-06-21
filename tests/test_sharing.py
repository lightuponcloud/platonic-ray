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


class SharingTest(TestClient):

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.user_id = self.client.user_id
        self.token = self.client.token
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_share_object(self):
        # upload object
        fn = "20180111_165127.jpg"
        url = "{}/riak/upload/{}/".format(BASE_URL, TEST_BUCKET_1)
        result = self.upload_file(url, fn)

        # share object
        url = "{}riak/share/{}/".format(self.client.url, TEST_BUCKET_1)
        headers = {
            "content-type": "application/json",
            "authorization": "Token {}".format(self.client.token),
        }
        data = {"object_keys": [fn]}
        response = requests.post(url, json=data, headers=headers)
        data = response.json()
        assert "token" in data
        assert "object_keys" in data
        assert fn in data["object_keys"]

        # retrieve share
        response = requests.get(url, headers=headers)
        data = response.json()
        assert len(data) == 1
        assert "shared_by" in data[0]
        assert "created_utc" in data[0]
        assert "object_key" in data[0]
        assert "token" in data[0]

        # delete share
        data = {"object_keys": [fn], "prefix": None}
        response = requests.delete(url, data=json.dumps(data), headers=headers)

        # make sure object is not shared anymore
        response = requests.get(url, headers=headers)
        data = response.json()
        assert data == []


if __name__ == "__main__":
    unittest.main()
