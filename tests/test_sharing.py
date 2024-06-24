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
from light_client import LightClient, generate_random_name, encode_to_hex


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
        data = {"tokens": [data[0]["token"]], "prefix": None}
        response = requests.delete(url, data=json.dumps(data), headers=headers)

        # make sure object is not shared anymore
        response = requests.get(url, headers=headers)
        data = response.json()
        assert data == []

    def test_share_pseudo_directory(self):
        # 1 Create pseudo-directory with random name
        dir_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(response.status_code, 204)

        hex_dir_name = encode_to_hex(dir_name)

        # upload object
        fn = "20180111_165127.jpg"
        url = "{}/riak/upload/{}/".format(BASE_URL, TEST_BUCKET_1)
        result = self.upload_file(url, fn, prefix=hex_dir_name)

        # share object
        url = "{}riak/share/{}/?prefix={}".format(self.client.url, TEST_BUCKET_1, hex_dir_name)
        headers = {
            "content-type": "application/json",
            "authorization": "Token {}".format(self.client.token),
        }
        data = {"object_keys": [fn], "prefix": hex_dir_name}
        response = requests.post(url, json=data, headers=headers)
        data = response.json()
        assert "token" in data
        assert "object_keys" in data
        assert fn in data["object_keys"]

        # retrieve share
        response = requests.get(url, headers=headers)
        data = response.json()
        self.assertEqual(len(data), 1)
        assert len(data) == 1
        assert "shared_by" in data[0]
        assert "created_utc" in data[0]
        assert "object_key" in data[0]
        assert "token" in data[0]

        # delete share
        data = {"tokens": [data[0]["token"]], "prefix": hex_dir_name}
        response = requests.delete(url, data=json.dumps(data), headers=headers)

        # make sure object is not shared anymore
        response = requests.get(url, headers=headers)
        data = response.json()
        assert data == []


if __name__ == "__main__":
    unittest.main()
