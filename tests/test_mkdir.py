import unittest
import time

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    TEST_BUCKET_3,
    USERNAME_1,
    PASSWORD_1,
    TestClient,
    ACTION_LOG_FILENAME,
    configure_boto3)
from light_client import (
    LightClient,
    generate_random_name,
    encode_to_hex,
    decode_from_hex)


class MKdirTest(TestClient):
    """
    Test operation MKDIR

    # 1. Upload file(create pseudo-directory)
    # 2. Try to create directory with the same name
    # 3. Make sure error returned
    """

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.client.login(USERNAME_1, PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_mkdir(self):
        """
        1. Сreates pseudo-directory
        2. Makes request to create another one with same name
        3. Checks for error returned
        """
        # 1 Create pseudo-directory with random name
        dir_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(response.status_code, 204)

        # Check SQLite db
        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)
        decoded_key = decode_from_hex(result[0]["key"])
        self.assertEqual(decoded_key, dir_name)
        self.assertEqual(result[0]["orig_name"], dir_name)
        self.assertEqual(result[0]["is_dir"], 1)
        self.assertEqual(result[0]["is_locked"], 0)
        self.assertTrue(("guid" in result[0]))
        self.assertEqual(result[0]["bytes"], 0)
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

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 1)
        mkdir_record = [i for i in action_log if i["action"] == "mkdir"][0]
        self.assertEqual(mkdir_record["orig_name"], dir_name)
        self.assertEqual(mkdir_record["details"], 'Created directory "{}/".'.format(dir_name))

        # 2 Try to create pseudo-directory with same name
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)

        # 3 Check for error is returned
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json(), {"error": 10})  # "10": "Directory exists already."

        # Make sure no additional records created in db
        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)

        # Clean: delete created pseudo-directory
        dir_name_prefix = [encode_to_hex(dir_name)]
        response = self.client.delete(TEST_BUCKET_1, dir_name_prefix)
        self.assertEqual(response.json(), dir_name_prefix)

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)

        action_log = self.check_sql(TEST_BUCKET_1, "SELECT * FROM actions", db_key=ACTION_LOG_FILENAME)
        self.assertEqual(len(action_log), 2)

    def test_mkdir_tenant_bucket(self):
        """
        Test creating directory in tenant's bucket.
        """
        # 1 Create pseudo-directory with random name
        dir_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_3, dir_name)
        self.assertEqual(response.status_code, 204)


if __name__ == '__main__':
    unittest.main()
