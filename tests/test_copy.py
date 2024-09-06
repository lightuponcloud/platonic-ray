import unittest
from pprint import pprint
import time

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    TEST_BUCKET_3,
    USERNAME_1,
    PASSWORD_1,
    USERNAME_2,
    PASSWORD_2,
    configure_boto3,
    ACTION_LOG_FILENAME,
    TestClient)
from light_client import LightClient, generate_random_name, encode_to_hex, decode_from_hex


class CopyTest(TestClient):
    """
    * user can't copy to different company bucket
    * file copy to the same directory
    """

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_copy_dir(self):
        # 1. create a directory
        dir_name1 = generate_random_name()
        hex_dir_name1 = encode_to_hex(dir_name1)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name1)

        dir_name2 = generate_random_name()
        hex_dir_name2 = encode_to_hex(dir_name2)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name2)

        response = self.client.copy(TEST_BUCKET_1, TEST_BUCKET_1,
            {hex_dir_name1: dir_name1}, "", hex_dir_name2)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], decode_from_hex(i['key'])) for i in result]

        assert ('', dir_name1) in keys
        assert (hex_dir_name2, dir_name1) in keys
        assert ('', dir_name2) in keys

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 3)
        copy_record = [i for i in action_log if i["action"] == "copy"][0]
        self.assertEqual(copy_record["details"], 'Copied "{}/" to "{}/".'.format(dir_name1, dir_name2))

    def test_copy_file(self):
        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        dir_name_prefix = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)

        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']
        orig_name = res["orig_name"]

        response = self.client.copy(TEST_BUCKET_1, TEST_BUCKET_1,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', object_key) in keys
        assert (hex_dir_name, object_key) in keys

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 3)
        copy_record = [i for i in action_log if i["action"] == "copy"][0]
        self.assertEqual(copy_record["details"], 'Copied "{}" to "{}/".'.format(fn, dir_name))

    def test_copy_file_tenant_bucket(self):
        """
        Test if delete works in tenant's bucket (no group).
        """
        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        dir_name_prefix = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_3, dir_name)

        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_3, fn)
        object_key = res['object_key']
        orig_name = res["orig_name"]

        response = self.client.copy(TEST_BUCKET_3, TEST_BUCKET_3,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_3, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', object_key) in keys
        assert (hex_dir_name, object_key) in keys

        action_log = self.check_sql(TEST_BUCKET_3, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 3)
        copy_record = [i for i in action_log if i["action"] == "copy"][0]
        self.assertEqual(copy_record["details"], 'Copied "{}" to "{}/".'.format(fn, dir_name))


if __name__ == "__main__":
    unittest.main()
