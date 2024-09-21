import unittest
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
    TestClient)
from light_client import LightClient, generate_random_name, encode_to_hex


class MoveTest(TestClient):
    """
    * user can't move to different company bucket
    * file move to the same directory
    """

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_move_dir(self):
        # 1. create a directory
        dir_name1 = generate_random_name()
        hex_dir_name1 = encode_to_hex(dir_name1)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name1)

        dir_name2 = generate_random_name()
        hex_dir_name2 = encode_to_hex(dir_name2)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name2)

        # upload file to directory
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn, prefix=hex_dir_name1)
        object_key = res['object_key']

        # move to subdir hex_dir_name2
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1,
            {hex_dir_name1: dir_name1}, "", hex_dir_name2)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]

        assert (hex_dir_name2, hex_dir_name1[:-1]) in keys
        assert ('', hex_dir_name2[:-1]) in keys
        assert ("{}{}".format(hex_dir_name2, hex_dir_name1), object_key) in keys

        # move directory 1 to root
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1,
            {hex_dir_name1: dir_name1}, hex_dir_name2, "")
        self.assertEqual(response.status_code, 200)

        time.sleep(3)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', hex_dir_name1[:-1]) in keys
        assert ('', hex_dir_name2[:-1]) in keys
        assert (hex_dir_name1, object_key) in keys

        # move to subdir hex_dir_name2 AGAIN
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1,
            {hex_dir_name1: dir_name1}, "", hex_dir_name2)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]

        assert (hex_dir_name2, hex_dir_name1[:-1]) in keys
        assert ('', hex_dir_name2[:-1]) in keys
        assert ("{}{}".format(hex_dir_name2, hex_dir_name1), object_key) in keys

    def test_move_file(self):
        time.sleep(1)
        self.purge_test_buckets()

        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)

        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        # move file to directory
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

        # check contents of db
        time.sleep(3)
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 2)
        keys = [(i['prefix'], i['key']) for i in result]
        assert (hex_dir_name, object_key) in keys

        # move to root
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1,
            {object_key: object_key}, hex_dir_name, "")
        self.assertEqual(response.status_code, 200)

        time.sleep(3)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 3)
        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', object_key) in keys

    def test_move_file_tenant_bucket(self):
        """
        Moving file in bucket that belongs to tenant (without particular group)
        """
        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_3, dir_name)

        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_3, fn)
        object_key = res['object_key']

        response = self.client.move(TEST_BUCKET_3, TEST_BUCKET_3,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

    def test_move_locked_file(self):
        """
        Moving locked file:
        - the one locked by author
        - the one locked by other user
        """
        time.sleep(1)
        self.purge_test_buckets()

        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_3, dir_name)

        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_3, fn)
        object_key = res['object_key']

        # lock it and check for "is_locked": True
        response = self.client.patch(TEST_BUCKET_3, "lock", [object_key])
        result = response.json()
        self.assertEqual(result[0]['is_locked'], True)
        self.assertEqual(response.status_code, 200)

        # move file to directory
        response = self.client.move(TEST_BUCKET_3, TEST_BUCKET_3,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_3, "SELECT * FROM items")
        self.assertEqual(len(result), 2)

        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', hex_dir_name[:-1]) in keys
        assert (hex_dir_name, object_key) in keys

        # lock again, after move
        response = self.client.patch(TEST_BUCKET_3, "lock", [object_key], prefix=hex_dir_name)
        result = response.json()
        self.assertEqual(result[0]['is_locked'], True)
        self.assertEqual(response.status_code, 200)

        # try move with another user ( not author of lock )
        client = LightClient(BASE_URL, USERNAME_2, PASSWORD_2)
        response = client.move(TEST_BUCKET_3, TEST_BUCKET_3,
            {object_key: object_key}, hex_dir_name, "")
        self.assertEqual(response.status_code, 200)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_3, "SELECT * FROM items")
        self.assertEqual(len(result), 3)

        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', hex_dir_name[:-1]) in keys
        assert (hex_dir_name, object_key) in keys
        assert ('', object_key) in keys  # file must be copied, not moved, when locked

    def test_file_move_between_buckets(self):
        """
        Make sure move operations works ok, when files and pseudo-dirs
        are moved between different buckets.
        """
        time.sleep(1)
        self.purge_test_buckets()

        # Upload a file
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        # move file to another bucket
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_3,
            {object_key: object_key}, "", "")
        self.assertEqual(response.status_code, 200)

        # check contents of db in source bucket
        time.sleep(2)
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)

        # check contents of db in dst bucket
        result = self.check_sql(TEST_BUCKET_3, "SELECT * FROM items")
        self.assertEqual(len(result), 1)

        keys = [(i['prefix'], i['key']) for i in result]
        assert ("", object_key) in keys

        # create directory in target bucket and move file there
        dir_name = generate_random_name()
        hex_dir_name = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)

        # move file to directory
        response = self.client.move(TEST_BUCKET_3, TEST_BUCKET_1,
            {object_key: object_key}, "", hex_dir_name)
        self.assertEqual(response.status_code, 200)

        # check contents of db
        time.sleep(3)
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 2)

        keys = [(i['prefix'], i['key']) for i in result]
        assert ("", hex_dir_name[:-1]) in keys
        assert (hex_dir_name, object_key) in keys

        result = self.check_sql(TEST_BUCKET_3, "SELECT * FROM items")
        self.assertEqual(len(result), 0)


if __name__ == "__main__":
    unittest.main()
