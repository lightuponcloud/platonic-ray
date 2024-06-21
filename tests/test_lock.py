import time
import unittest

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    TEST_BUCKET_3,
    USERNAME_1,
    PASSWORD_1,
    USERNAME_2,
    PASSWORD_2,
    TestClient)
from light_client import LightClient, generate_random_name, encode_to_hex


class LockTest(TestClient):
    """
    Test operation LOCK / UNLOCK

    # 1. upload file, lock it
    # 2. make sure lock is set
    # 3. try to change lock from different user
    # 4. make sure the same value of lock remained as in step #2
    #

    #
    # upload file, lock it, upload new version from the same user
    # lock should remain
    #

    #
    # Make sure locked file can't be replaced using MOVE operations
    #

    #
    # Make sure locked file can't be replaced using COPY operation from other User
    #

    #
    # Make sure deleted objects can't be locked
    #

    #
    # 1. Lock file in pseudo-dir
    # 2. delete dir
    # 3. Make sure only locked file remains
    #
    """

    def setUp(self):
        super(LockTest, self).setUp()
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)

    def test_lock(self):
        """
        Upload file and lock it,
        check for lock is.
        Try to change lock from different user,
        make sure the same value of lock remained as in step #2
        """
        # 1. upload 1 file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn)
        object_key = result['object_key']
        self.assertEqual(result['orig_name'], fn)

        # 2-3. lock it and check for "is_locked": True
        response = self.client.patch(TEST_BUCKET_1, "lock", [object_key])
        result = response.json()
        # print(response.content.decode())
        self.assertEqual(result[0]['is_locked'], True)
        self.assertEqual(response.status_code, 200)

        time.sleep(1)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(result[0]['is_locked'], 1)

        # 4. try to change lock from different user
        self.client.login(USERNAME_2, PASSWORD_2)
        response = self.client.patch(TEST_BUCKET_1, "unlock", [object_key])
        result = response.json()
        # print(response.status_code)
        # print(response.content.decode())
        # Lock remains active, as unlock was performed by different user
        self.assertEqual(result[0]['is_locked'], True)

        time.sleep(1)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(result[0]['is_locked'], 1)

        # 5. Check for the same value of lock remained as in step #2-3
        response = self.client.get_list(TEST_BUCKET_1)
        result = response.json()
        for obj in result['list']:
            if obj['object_key'] == object_key:
                self.assertEqual(obj['is_locked'], True)

        # 6. Unlock file by lock owner
        self.client.login(USERNAME_1, PASSWORD_1)
        response = self.client.patch(TEST_BUCKET_1, "unlock", [object_key])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()[0]['is_locked'], False)

        time.sleep(1)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(result[0]['is_locked'], 0)

        # Delete file
        response = self.client.delete(TEST_BUCKET_1, [object_key])
        self.assertEqual(response.status_code, 200)

        time.sleep(1)  # time necessary for server to update db
        result = self.check_sql(TEST_BUCKET_1, "SELECT * FROM items")
        self.assertEqual(result, [])

    def test_lock_and_newversion(self):
        """
        upload file, lock it, upload new version from the same user
        check for lock is remain
        """
        # 1. upload a file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn)
        object_key1 = result['object_key']
        self.assertTrue(result['orig_name'].startswith("20180111_165127"))

        # 2-3. lock it and check for "is_locked": True
        response = self.client.patch(TEST_BUCKET_1, "lock", [object_key1])
        result = response.json()
        # print(response.content.decode())
        self.assertEqual(result[0]['is_locked'], True)
        self.assertEqual(response.status_code, 200)

        # 4. get current version from list
        response = self.client.get_list(TEST_BUCKET_1)
        last_seen_version = None
        for obj in response.json()['list']:
            if obj['object_key'] == object_key1:
                # print(obj['version'])
                last_seen_version = obj["version"]
        self.assertIsNotNone(last_seen_version)

        # 5. upload new version of file from the same user
        result = self.client.upload(TEST_BUCKET_1, fn, last_seen_version=last_seen_version)
        # print(result)
        object_key2 = result['object_key']
        self.assertEqual(result['orig_name'], fn)
        self.assertEqual(result['is_locked'], True)
        self.assertNotEqual(result['version'], last_seen_version)

        response = self.client.get_list(TEST_BUCKET_1)
        last_seen_version = None
        for obj in response.json()['list']:
            if obj['object_key'] == object_key2:
                last_seen_version = obj["version"]

        # 5.1 unlock file and delete
        response = self.client.patch(TEST_BUCKET_1, "unlock", [object_key1])
        self.assertEqual(response.json()[0]['is_locked'], False)
        self.assertEqual(response.status_code, 200)

        response = self.client.delete(TEST_BUCKET_1, [object_key2])
        self.assertEqual(response.status_code, 200)

    def test_lock3(self):
        """
        Make sure locked file can't be replaced using COPY/MOVE operations
        """
        # 1.1 upload a file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn)
        object_key1 = result['object_key']
        version = result['version']
        self.assertEqual(result['orig_name'], fn)

        # 1.2 create a directory
        dir_name = generate_random_name()
        dir_name_prefix = encode_to_hex(dir_name)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(response.status_code, 204)

        result = self.client.upload(TEST_BUCKET_1, fn, prefix=dir_name_prefix, last_seen_version=version)
        object_key2 = result['object_key']
        self.assertNotEqual(version, result['version'])

        # 2. lock first file and check for "is_locked": True
        response = self.client.patch(TEST_BUCKET_1, "lock", [object_key1])
        result = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(result[0]['is_locked'], True)

        # 3.1 Try to replace locked file by second file from directory by move operation
        src_object_keys = [object_key2]
        response = self.client.move(TEST_BUCKET_1, TEST_BUCKET_1, src_object_keys, src_prefix=dir_name_prefix)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json(), {"error": 15})  # "15": "Incorrect \"src_object_keys\"."

        # 3.2 check for locked file existance and is_locked: True
        response = self.client.get_list(TEST_BUCKET_1)
        for obj in response.json()['list']:
            if obj['object_key'] == object_key1:
                self.assertEqual(obj['orig_name'], fn)
                self.assertEqual(obj['is_locked'], True)
                break
        else:
            self.assertTrue(False, msg='Uploaded file disapeared somewhere')

        # 3.3 Delete uploaded file from directory
        response = self.client.delete(TEST_BUCKET_1, [object_key2], dir_name_prefix)
        self.assertEqual(response.json(), [object_key2])

        # 4.1 Upload the same file with new version from User2
        self.client.login(USERNAME_2, PASSWORD_2)
        result = self.client.upload(TEST_BUCKET_1, fn, prefix=dir_name_prefix, last_seen_version=version)
        object_key3 = result['object_key']
        self.assertEqual(result['orig_name'], fn)
        self.assertNotEqual(version, result['version'])

        # 4.2 Try to replace locked file by second file from directory by copy operation
        object_keys = {object_key3: fn}
        response = self.client.copy(TEST_BUCKET_1, TEST_BUCKET_1, object_keys, dir_name_prefix)
        # print(response.content.decode())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok'})

        # 4.2 check for locked file existance and is_locked: True
        response = self.client.get_list(TEST_BUCKET_1)
        for obj in response.json()['list']:
            if obj['object_key'] == object_key1:
                self.assertEqual(obj['orig_name'], fn)
                self.assertEqual(obj['is_locked'], True)
                break
        else:
            self.assertTrue(False, msg='Uploaded file disapeared somewhere')

        # 4.3 Clean: delete uploaded file from User2
        response = self.client.delete(TEST_BUCKET_1, [object_key3], dir_name_prefix)
        self.assertEqual(response.json(), [object_key3])

        # Clean: delete the uploaded file and directory from User1
        self.client.login(USERNAME_1, PASSWORD_1)
        response = self.client.patch(TEST_BUCKET_1, "unlock", [object_key1])
        self.assertEqual(response.json()[0]['is_locked'], False)
        self.assertEqual(response.status_code, 200)
        object_keys = [object_key1, dir_name_prefix]
        response = self.client.delete(TEST_BUCKET_1, object_keys)
        self.assertEqual(response.status_code, 200)
        # WRONG RESPONSE CONTENT - DELETE OPERATION !!!
        # self.assertEqual(set(response.json()), set(object_keys))

    def test_lock4(self):
        """
        Make sure deleted objects can't be locked
        """
        print("test_lock4 start")
        # 1. upload a file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_1, fn)
        object_key = [result['object_key']]
        self.assertTrue(result['orig_name'].startswith("20180111_165127"))

        # 2. delete it
        response = self.client.delete(TEST_BUCKET_1, object_key)
        object_key_deleted = response.json()
        self.assertEqual(object_key_deleted, object_key)
        print(response.json())
        self.assertEqual(response.status_code, 200)

        metadata = self.head(TEST_BUCKET_1, object_key_deleted[0])
        self.assertTrue(metadata.get('is-locked', False) in [False, 'undefined'])
        self.assertTrue(metadata.get('is-deleted', True))

        # 3. try to lock deleted file
        response = self.client.patch(TEST_BUCKET_1, 'lock', object_key_deleted)
        self.assertEqual(response.status_code, 200)

        metadata = self.head(TEST_BUCKET_1, object_key_deleted[0])
        # It should not be possible to lock deleted files
        self.assertTrue(metadata.get('is-locked', False) in [False, 'undefined'])

    def test_lock_tenant_bucket(self):
        """
        Make sure lock works in bucket of tenant (without group)
        """
        # 1. upload 1 file
        fn = "20180111_165127.jpg"
        result = self.client.upload(TEST_BUCKET_3, fn)
        object_key = result['object_key']

        # 2-3. lock it and check for "is_locked": True
        response = self.client.patch(TEST_BUCKET_3, "lock", [object_key])
        result = response.json()
        # print(response.content.decode())
        self.assertEqual(result[0]['is_locked'], True)
        self.assertEqual(response.status_code, 200)


if __name__ == '__main__':
    unittest.main()
