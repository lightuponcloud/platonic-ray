import unittest
import time

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    USERNAME_1,
    PASSWORD_1,
    ACTION_LOG_FILENAME,
    configure_boto3,
    TestClient)
from light_client import LightClient, generate_random_name, encode_to_hex


class RenameTest(TestClient):
    """
    #
    # Rename pseudo-directory:
    # * source prefix do not exist
    # * pseudo-directory exists ( but in lower/uppercase )
    # * server failed to rename some nested objects
    #
    #
    # To make sure error returned in the following cases.
    # * rename directory to the name of existing file
    # * rename file to the name of existing directory
    #
    # 1. rename file
    # 2. create directory with the same name
    # 3. make sure error appears
    #
    #
    # 1. rename file to the same name but with different case ( uppercase / lowercase )
    # 2. to make sure no server call made
    #
    #
    # 1. to create directory on client in UPPERCASE when LOWERCASE exists on server
    # 2. to make sure files put in NTFS directory uploaded to remote dir using server name,
    #    not client name.
    #

    #
    # 1. to lock file
    # 2. to rename it
    # 3. make sure it is not renamed
    #

    #
    # 1. to upload two files
    # 2. to lock second file
    # 3. to rename one of them to the name of the second one
    # 4. to make sure rename is not allowed
    #

    #
    # 1. upload file
    # 2. rename it
    # 3. rename it to its key
    # 4. file should not disappear
    #
    #
    # 1. rename object to the key that exists in destination directory
    # 2. move to the destination directory
    # 3. previous object, with different orig name, should not be replaced
    #
    """

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_sqlite_update(self):
        # 1. Upload file
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["key"], fn)
        self.assertEqual(result[0]["orig_name"], fn)
        self.assertEqual(result[0]["is_dir"], 0)

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 1)

        # 2. Rename file
        random_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, object_key, random_name)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()['orig_name'], random_name)

        time.sleep(2)  # time necessary for server to update db
        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 2)
        rename_record = [i for i in action_log if i["action"] == "rename"][0]
        self.assertEqual(rename_record["orig_name"], random_name)
        self.assertEqual(rename_record["details"], 'Renamed "{}" to "{}"'.format(fn, random_name))

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["orig_name"], random_name)
        self.assertEqual(result[0]["is_dir"], 0)
        self.assertEqual(result[0]["is_locked"], 0)
        self.assertEqual(result[0]["bytes"], 2773205)
        self.assertTrue(("guid" in result[0]))
        self.assertTrue(("bytes" in result[0]))
        self.assertTrue(("version" in result[0]))
        self.assertTrue(("last_modified_utc" in result[0]))
        self.assertTrue(("author_id" in result[0]))
        self.assertTrue(("author_name" in result[0]))
        self.assertTrue(("author_tel" in result[0]))
        self.assertTrue(("lock_user_id" in result[0]))
        self.assertTrue(("lock_user_name" in result[0]))
        self.assertTrue(("lock_user_tel" in result[0]))
        self.assertTrue(("lock_modified_utc" in result[0]))
        self.assertTrue(("md5" in result[0]))

        # 3. Create directory with different name
        random_dir_name = generate_random_name()
        res = self.client.create_pseudo_directory(TEST_BUCKET_1, random_dir_name)
        self.assertEqual(res.status_code, 204)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 2)
        names = [i["orig_name"] for i in result]
        self.assertEqual(set(names), set([random_name, random_dir_name]))
        self.assertEqual(result[0]["is_dir"], 0)
        self.assertEqual(result[0]["is_locked"], 0)
        self.assertEqual(result[0]["bytes"], 2773205)

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 3)
        mkdir_record = [i for i in action_log if i["action"] == "mkdir"][0]
        self.assertEqual(mkdir_record["orig_name"], random_dir_name)
        self.assertEqual(mkdir_record["details"], 'Created directory "{}/".'.format(random_dir_name))

        # Create dir with prefix
        random_prefix = generate_random_name()
        res = self.client.create_pseudo_directory(TEST_BUCKET_1, random_prefix)
        self.assertEqual(res.status_code, 204)

        time.sleep(2)  # time necessary for server to update db
        encoded_prefix = encode_to_hex(random_prefix)
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertTrue(encoded_prefix in ["{}/".format(i['key']) for i in result])
        self.assertEqual(len(result), 3)

        random_dir_name = generate_random_name()
        encoded_random_prefix = encode_to_hex(random_prefix)
        res = self.client.create_pseudo_directory(TEST_BUCKET_1, random_dir_name,
                                                  prefix=encoded_random_prefix)
        self.assertEqual(res.status_code, 204)

        time.sleep(2)  # time necessary for server to update db
        encoded_prefix = encode_to_hex(random_prefix)
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 4)
        self.assertTrue(encode_to_hex(random_dir_name) in ["{}/".format(i['key']) for i in result])
        self.assertTrue(encoded_random_prefix in [i['prefix'] for i in result])

        prefixed_action_log = "{}{}".format(encoded_prefix, ACTION_LOG_FILENAME)
        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=prefixed_action_log)
        self.assertEqual(len(action_log), 1)
        mkdir_record = [i for i in action_log if i["action"] == "mkdir"][0]
        self.assertEqual(mkdir_record["orig_name"], random_dir_name)
        self.assertEqual(mkdir_record["details"], 'Created directory "{}/".'.format(random_dir_name))

        # rename nested pseudo-dir

        fn = "20180111_165127.jpg"
        old_file_prefix = "{}{}".format(encoded_random_prefix, encode_to_hex(random_dir_name))
        res = self.client.upload(TEST_BUCKET_1, fn, prefix=old_file_prefix)
        object_key = res['object_key']

        random_new_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, encode_to_hex(random_dir_name), random_new_name,
                                 prefix=encoded_random_prefix)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()['dir_name'], random_new_name)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 5)

        prefixed_action_log = "{}{}".format(encoded_random_prefix, ACTION_LOG_FILENAME)
        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=prefixed_action_log)
        self.assertEqual(len(action_log), 2)
        rename_dir_record = [i for i in action_log if i["action"] == "rename"][0]
        self.assertEqual(rename_dir_record["orig_name"], random_new_name)
        self.assertEqual(rename_dir_record["details"], 'Renamed "{}" to "{}"'.format(random_dir_name, random_new_name))

        keys = [(i['prefix'], i['key']) for i in result]
        assert (encoded_random_prefix, encode_to_hex(random_new_name)[:-1]) in keys
        new_file_prefix = old_file_prefix.replace(encode_to_hex(random_dir_name), encode_to_hex(random_new_name))
        assert (new_file_prefix, object_key) in keys

        dir_index = None
        for idx, dct in enumerate(result):
            if dct["orig_name"] == random_new_name:
                dir_index = idx
                break
        self.assertTrue(dir_index is not None)
        self.assertTrue(result[dir_index]["prefix"] == encoded_random_prefix)
        self.assertTrue("{}/".format(result[dir_index]['key']), encode_to_hex(random_new_name))

        # rename root pseudo-dir
        another_random_new_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, encoded_random_prefix, another_random_new_name)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()['dir_name'], another_random_new_name)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 5)

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 5)
        rename_dir_records = [i for i in action_log if i["action"] == "rename"]
        self.assertEqual((another_random_new_name in [i['orig_name'] for i in rename_dir_records]), True)

        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', encode_to_hex(another_random_new_name)[:-1]) in keys
        assert (encode_to_hex(another_random_new_name), encode_to_hex(random_new_name)[:-1]) in keys
        assert ("{}{}".format(encode_to_hex(another_random_new_name), encode_to_hex(random_new_name)), object_key) in keys


if __name__ == '__main__':
    unittest.main()
