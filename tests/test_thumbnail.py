import os
import time
import unittest
from base64 import b64encode, b64decode
import json
import hashlib

import requests
from botocore import exceptions

from dvvset import DVVSet
from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    USERNAME_1,
    PASSWORD_1,
    PASSWORD_2,
    configure_boto3,
    TestClient)
from light_client import LightClient, generate_random_name, encode_to_hex


class UploadTest(TestClient):

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.user_id = self.client.user_id
        self.token = self.client.token
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_thumbnail_success(self):
        fn = "20180111_165127.jpg"
        url = "{}/riak/upload/{}/".format(BASE_URL, TEST_BUCKET_1)
        result = self.upload_file(url, fn)

        fn = "246x0w.png"
        object_key = "20180111_165127.jpg"
        url = "{}/riak/thumbnail/{}/?object_key={}".format(BASE_URL, TEST_BUCKET_1, object_key)
        # t1 = time.time()
        result = self.upload_thumbnail(url, fn, object_key, form_data={"width": 2560, "height":1600})

        # check if correct thumbnail returned
        response = requests.get(url, headers=self.get_default_headers())
        self.assertEqual(response.status_code, 200)

        response_md5 = hashlib.md5(response.content).hexdigest()
        self.assertEqual(response_md5, '274a1939f67a3f036c8d0ab763d67c65')

        # t2 = time.time()

    def test_prefixed_thumbnail_success(self):
        dir_name = "test"
        dir_response = self.create_pseudo_directory(dir_name)
        self.assertEqual(dir_response.status_code, 204)
        hex_prefix = dir_name.encode().hex()

        fn = "20180111_165127.jpg"
        url = "{}/riak/upload/{}/".format(BASE_URL, TEST_BUCKET_1)
        result = self.upload_file(url, fn, prefix=hex_prefix)

        fn = "246x0w.png"
        object_key = "20180111_165127.jpg"
        url = "{}/riak/thumbnail/{}/{}/?object_key={}".format(BASE_URL, TEST_BUCKET_1, hex_prefix, object_key)
        t1 = time.time()
        form_data = {
            "width": 2560,
            "height":1600,
            "prefix": hex_prefix
        }
        result = self.upload_thumbnail(url, fn, object_key, form_data=form_data)

        # check if correct thumbnail returned
        response = requests.get(url, headers=self.get_default_headers())
        self.assertEqual(response.status_code, 200)

        response_md5 = hashlib.md5(response.content).hexdigest()
        self.assertEqual(response_md5, '274a1939f67a3f036c8d0ab763d67c65')

        # t2 = time.time()


if __name__ == "__main__":
    unittest.main()
