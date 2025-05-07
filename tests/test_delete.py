import unittest
import random
import time

from client_base import (
    BASE_URL,
    REGION,
    USERNAME_1,
    PASSWORD_1,
    TEST_BUCKET_1,
    USER_1_API_KEY,
    TestClient,
    generate_random_name,
    encode_to_hex,
    configure_boto3)
from light_client import LightClient


class DeleteTest(TestClient):
    """
    Operation DELETE tests

    # Delete with empty object_keys
    #
    # Delete from root
    #
    # Delete from pseudo-directory
    #
    # Delete pseudo-directory from root
    #
    # Delete pseudo-directory with prefix(from pseudo-directory)
    """

    def setUp(self):
        self.client = LightClient(REGION, BASE_URL, username=USERNAME_1, password=PASSWORD_1)
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def test_delete_none(self):
        """
        negative test case - empty object_keys sent
        """
        object_keys = []
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        result = response.json()
        self.assertEqual(result, {"error": 34})  # "34": "Empty "object_keys"."

    def test_delete_files_from_root(self):
        """
        # Delete files from root: one and many
        """
        # upload 1 file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn)
        self.assertEqual(result['orig_name'], fn)

        # delete 1 uploaded file
        object_keys = [fn]
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        result = response.json()
        self.assertEqual(result, [fn])

        # upload many files
        fn = ["246x0w.png", "README.md", "requirements.txt"]
        object_keys = []
        for file in fn:
            result = self.client.upload(TEST_BUCKET_1, file)
            object_keys.append(result['object_key'])
            self.assertEqual(result['orig_name'], file)

        # delete uploaded files and final check for "is_deleted": True
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        self.assertTrue(not set(object_keys) ^ set(response.json()))

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)

        response = self.client.get_list(TEST_BUCKET_1)
        result = response.json()

        for filename in fn:
            for obj in result['list']:
                if filename in obj['orig_name']:
                    self.assertEqual(obj['is_deleted'], True)

    def test_delete_files_from_pseudodirectory(self):
        """
        # Delete from pseudo-directory: one and many
        """

        # 1 create main pseudo-directory
        dir_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        assert response.status_code == 204
        dir_name_prefix = dir_name.encode().hex() + "/"

        # 2 upload file to main pseudo-directory
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn, dir_name_prefix)
        self.assertEqual(result['orig_name'], '20180111_165127.jpg')
        object_key = [result['object_key']]

        # 2.1 delete file from pseudo-directory and check for is_deleted: True
        response = self.client.delete(TEST_BUCKET_1, object_keys=object_key, prefix=dir_name_prefix)
        import pdb;pdb.set_trace()
        self.assertEqual(response.json(), object_key)

        result = self.client.get_list(TEST_BUCKET_1).json()
        for obj in result['list']:
            if fn in obj['orig_name']:
                self.assertTrue(obj['is_deleted'])

        # 3 upload many files to main pseudo-directory
        fn = ["246x0w.png", "README.md", "requirements.txt"]
        object_keys = []
        for file in fn:
            result = self.client.upload(TEST_BUCKET_1, file, dir_name_prefix)
            object_keys.append(result['object_key'])
            self.assertEqual(result['orig_name'], file)

        # 4 delete created pseudo-directory, with uploaded files
        dir_name_prefix = [dir_name_prefix]
        response = self.client.delete(TEST_BUCKET_1, object_keys=dir_name_prefix)
        self.assertEqual(response.json(), dir_name_prefix)

    def test_delete_pseudodirectories_from_root(self):
        """
        # Delete pseudo-directories from root: one and many
        """
        # create 1 pseudo-directory
        dir_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(response.status_code, 204)
        dir_name_prefix = dir_name.encode().hex() + "/"

        # delete created pseudo-directory
        response = self.client.delete(TEST_BUCKET_1, [dir_name_prefix])
        result = response.json()
        self.assertEqual(result, [dir_name_prefix])

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)

        # create directories
        dir_names = [generate_random_name() for _ in range(3)]
        for name in dir_names:
            response = self.client.create_pseudo_directory(TEST_BUCKET_1, name)
            assert response.status_code == 204

        # delete directories
        object_keys = encode_to_hex(dir_names=dir_names)
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        assert response.status_code == 200
        result = response.json()
        self.assertEqual(set(result), set(object_keys))

        # deleting hierarchy of directories
        first_name = generate_random_name()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, first_name)
        assert response.status_code == 204
        for _ in range(4):
            name = generate_random_name()
            response = self.client.create_pseudo_directory(TEST_BUCKET_1, name,
                prefix=encode_to_hex(dir_name=first_name))
            assert response.status_code == 204

        response = self.client.delete(TEST_BUCKET_1, [encode_to_hex(dir_name=first_name)])
        assert response.status_code == 200
        result = response.json()
        self.assertEqual(set(result), set([encode_to_hex(dir_name=first_name)]))

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)

    def test_delete_pseudodirectories_from_pseudodirectory(self):
        """
        # Delete pseudo-directories from pseudo-directory: one and many
        """
        # create main pseudo-directory
        main_dir_name = generate_random_name()
        main_dir_name_prefix = encode_to_hex(main_dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, main_dir_name)
        self.assertEqual(response.status_code, 204)

        # create 1 pseudo-directory in main pseudo-directory
        nested_dir_name = generate_random_name()
        nested_dir_name_prefix = encode_to_hex(nested_dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, nested_dir_name, main_dir_name_prefix)
        self.assertFalse(bool(response.content), msg=response.content.decode())
        self.assertEqual(response.status_code, 204)

        # delete 1 created pseudo-directory from main pseudo-directory
        object_keys = [nested_dir_name_prefix]

        response = self.client.delete(TEST_BUCKET_1, object_keys, prefix=main_dir_name_prefix)
        assert response.status_code == 200
        self.assertEqual(set(response.json()), set(object_keys))

        time.sleep(2)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 1)  # only main dir should exist

        # create 2-10 pseudo-directories in main pseudo-directory
        dir_names = [generate_random_name() for _ in range(random.randint(2, 10))]
        object_keys = encode_to_hex(dir_names=dir_names)
        for name in dir_names:
            response = self.client.create_pseudo_directory(TEST_BUCKET_1, name)
            assert response.status_code == 204

        # delete created pseudo-directories from main pseudo-directory
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        assert response.status_code == 200
        self.assertEqual(set(response.json()), set(object_keys))

        # delete main pseudo-directory
        object_keys = [main_dir_name_prefix]
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        assert response.status_code == 200
        self.assertEqual(set(response.json()), set(object_keys))

        time.sleep(4)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(len(result), 0)  # only main dir should exist

    def test_delete_undelete_files_in_root(self, prefix=None):
        """
        # Restore deleted files in root dir: one and many
        """
        # Upload 1 file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn, prefix=prefix)
        self.assertEqual(result['orig_name'], fn)

        # Delete 1 uploaded file
        object_keys = [fn]
        response = self.client.delete(TEST_BUCKET_1, object_keys, prefix=prefix)
        result = response.json()
        self.assertEqual(result, [fn])

        response = self.client.get_list(TEST_BUCKET_1, prefix=prefix)
        result = response.json()

        # Make sure file is marked as deleted
        for filename in [fn]:
            for obj in result['list']:
                if filename == obj['orig_name']:
                    self.assertEqual(obj['is_deleted'], True)

        response = self.client.patch(TEST_BUCKET_1, "undelete", object_keys, prefix=prefix)
        self.assertEqual(response.status_code, 204)

        time.sleep(2)

        # Check DB
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        rec = [i for i in result if i['key'] == fn][0]
        expected_prefix = ''
        if prefix:
            expected_prefix = prefix
        self.assertEqual(rec['prefix'], expected_prefix)
        self.assertEqual(rec['key'], fn)
        self.assertEqual(rec['orig_name'], fn)
        self.assertEqual(rec['is_dir'], 0)
        self.assertEqual(rec['is_locked'], 0)
        self.assertEqual(rec['bytes'], 2773205)
        self.assertTrue(('guid' in rec))
        self.assertTrue(rec['guid'])
        self.assertTrue(('version' in rec))
        self.assertTrue(rec['version'])
        self.assertTrue(('last_modified_utc' in rec))
        self.assertTrue(rec['last_modified_utc'])
        self.assertTrue(('author_id' in rec))
        self.assertTrue(rec['author_id'])
        self.assertTrue(('author_name' in rec))
        self.assertTrue(rec['author_name'])
        self.assertTrue(('author_tel' in rec))
        self.assertTrue(('lock_user_id' in rec))
        self.assertTrue(('lock_user_name' in rec))
        self.assertTrue(('lock_user_tel' in rec))
        self.assertTrue(('lock_modified_utc' in rec))
        self.assertTrue(('md5' in rec))
        self.assertTrue(rec['md5'])

        response = self.client.get_list(TEST_BUCKET_1, prefix=prefix)
        result = response.json()

        # Make sure file is restored
        for filename in [fn]:
            for obj in result['list']:
                if filename == obj['orig_name']:
                    self.assertEqual(obj['is_deleted'], False)

    def test_delete_undelete_files_in_prefix(self):
        # 1. create a directory
        dir_name1 = generate_random_name()
        hex_dir_name1 = encode_to_hex(dir_name1)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name1)
        self.assertEqual(response.status_code, 204)

        self.test_delete_undelete_files_in_root(prefix=hex_dir_name1)

    def test_delete_undelete_directories_in_root(self, prefix=None):
        """
        # Restore deleted files in root dir: one and many
        """
        # 1. create a directory
        dir_name1 = generate_random_name()
        hex_dir_name1 = encode_to_hex(dir_name1)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name1, prefix=prefix)
        self.assertEqual(response.status_code, 204)

        # Upload 1 file to directory
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn, prefix="{}{}".format((prefix or ''), hex_dir_name1))
        self.assertEqual(result['orig_name'], fn)

        # Delete directory
        object_keys = [hex_dir_name1]
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertEqual(result, [hex_dir_name1])

        response = self.client.get_list(TEST_BUCKET_1, prefix=prefix, show_deleted=True)
        result = response.json()

        # Make sure directory is marked as deleted
        for item in result['dirs']:
            if bytes.fromhex(item['prefix'][:-1]) == dir_name1:
                self.assertEqual(item['is_deleted'], True)

        response = self.client.patch(TEST_BUCKET_1, "undelete", object_keys, prefix=prefix)
        self.assertEqual(response.status_code, 204)

        time.sleep(2)

        # Check DB
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(result, [])

        response = self.client.get_list(TEST_BUCKET_1, prefix=prefix, show_deleted=True)
        result = response.json()

        # Make sure file is restored
        for filename in [fn]:
            for obj in result['list']:
                if filename == obj['orig_name']:
                    self.assertEqual(obj['is_deleted'], False)

if __name__ == '__main__':
    unittest.main()
