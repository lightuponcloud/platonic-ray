import unittest
import time
import os

import requests

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    USERNAME_1,
    PASSWORD_1,
    ACTION_LOG_FILENAME,
    REGION,
    configure_boto3,
    TestClient)
from light_client import LightClient


class ListTest(TestClient):
    """
    Make sure listing available to authenticated users OR by signature.
    """
    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_list(self):
        # 1. Upload file
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']
        guid = res['guid']

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["key"], fn)
        self.assertEqual(result[0]["orig_name"], fn)
        self.assertEqual(result[0]["is_dir"], 0)

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 1)

        # use admin API key to fetch tenants
        api_key = os.getenv("ADMIN_API_KEY")

        url = "{}/riak/admin/tenants/".format(BASE_URL)
        headers={"authorization": "Token {}".format(api_key)}
        response = requests.get(url, headers=headers, timeout=5)
        self.assertEqual(response.status_code, 200)
        data = response.json()
        tenant = [i for i in data if i['id'] == "integrationtests"]
        assert tenant
        api_key = tenant[0]['api_key']

        signature = self.client.calculate_url_signature(REGION, "get", TEST_BUCKET_1, "", api_key)

        url = "{}/riak/list/{}/?signature={}".format(BASE_URL, TEST_BUCKET_1, signature)
        response = requests.get(url, timeout=2)
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertTrue(('list' in data))
        self.assertEqual(len(data['list']), 1)
        record = data['list'][0]

        self.assertEqual(record['object_key'], fn)
        self.assertEqual(record['orig_name'], fn)
        self.assertEqual(record['guid'], guid)
        self.assertEqual(record['width'], 3264)
        self.assertEqual(record['height'], 2448)
        self.assertEqual(record['md5'], 'd41d8cd98f00b204e9800998ecf8427e')
        self.assertEqual(record['bytes'], 2773205)
        self.assertEqual(record['content_type'], 'image/jpeg')
        self.assertEqual(record['is_deleted'], False)
        self.assertEqual(record['is_locked'], False)
        self.assertTrue(('copy_from_guid' in record))
        self.assertTrue(('copy_from_bucket_id' in record))
        self.assertTrue(('upload_id' in record))
        self.assertTrue(('upload_time' in record))
        self.assertTrue(('author_id' in record))
        self.assertTrue(('author_name' in record))
        self.assertTrue(('author_tel' in record))
        self.assertTrue(('lock_user_id' in record))
        self.assertTrue(('lock_user_name' in record))
        self.assertTrue(('lock_user_tel' in record))
        self.assertTrue(('lock_modified_utc' in record))

        # negative test
        url = "{}/riak/list/{}/?signature={}".format(BASE_URL, TEST_BUCKET_1, "something")
        response = requests.get(url, timeout=2)

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json(), {'error': 28})


if __name__ == '__main__':
    unittest.main()
