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
    TEST_BUCKET_2,
    TEST_BUCKET_3,
    FILE_UPLOAD_CHUNK_SIZE,
    UPLOADS_BUCKET_NAME,
    RIAK_ACTION_LOG_FILENAME,
    USERNAME_1,
    PASSWORD_1,
    USERNAME_2,
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

        url = "{}/riak/thumbnail/{}/".format(BASE_URL, TEST_BUCKET_1)
        fn = "246x0w.png"
        object_key = "20180111_165127.jpg"
        t1 = time.time()
        result = self.upload_thumbnail(url, fn, object_key, form_data={"width": 2560, "height":1600})

        # check if correct thumbnail returned
        response = requests.get("{}?object_key={}".format(url, object_key),
            headers=self.get_default_headers())
        self.assertEqual(response.status_code, 200)

        response_md5 = hashlib.md5(response.content).hexdigest()
        self.assertEqual(response_md5, '274a1939f67a3f036c8d0ab763d67c65')

        t2 = time.time()
        print("Upload thumbnail {}".format(int(t2-t1)))

if __name__ == "__main__":
    unittest.main()
