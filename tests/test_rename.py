import unittest
from pprint import pprint
import time

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    USERNAME_1,
    PASSWORD_1,
    USERNAME_2,
    PASSWORD_2,
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

    def test_negative_case1(self):
        """
        # Rename pseudo-directory:
        # * source prefix do not exist
        """
        # 1. create a directory
        dir_name = generate_random_name()
        prefix = encode_to_hex(dir_name)
        random_dir_name = (generate_random_name(), generate_random_name())
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)

        # 2.1 try to rename directory that doesn't exists in root
        res = self.client.rename(TEST_BUCKET_1, encode_to_hex(random_dir_name[0]), random_dir_name[1])
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {"error": 11})  # "11": "Prefix do not exist.",

        # 2.2 try to rename directory that doesn't exists in created directory
        res = self.client.rename(TEST_BUCKET_1, encode_to_hex(random_dir_name[0]), random_dir_name[1], prefix)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {"error": 11})

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [prefix])

    def test_negative_case2(self):
        """
        # Rename pseudo-directory:
        # * pseudo-directory exists ( but in lower/uppercase )
        """
        # 1.1 create a directory with lower_case name
        dir_name1 = generate_random_name().lower()
        prefix1 = encode_to_hex(dir_name1)
        random_dir_name1 = generate_random_name()
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name1)

        # 1.2 try to rename lower_case name directory by upper_case key
        res = self.client.rename(TEST_BUCKET_1, encode_to_hex(dir_name1.upper()), random_dir_name1)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {"error": 11})  # "11": "Prefix do not exist.",

        # 2.1 create a directory with upper_case name
        dir_name2 = generate_random_name().upper()
        prefix2 = encode_to_hex(dir_name2)
        random_dir_name2 = generate_random_name()
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name2)

        # 2.2 try to rename upper_case name directory by lower_case key
        res = self.client.rename(TEST_BUCKET_1, encode_to_hex(dir_name2.lower()), random_dir_name2)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {"error": 11})

        # Clean: delete created directories
        self.client.delete(TEST_BUCKET_1, [prefix1, prefix2])

    def test_negative_case3(self):
        """
        # Rename pseudo-directory:
        # * server failed to rename some nested objects
        """
        # 1.1 create a directory and a nested directory into
        dir_names = [generate_random_name() for i in range(2)]
        hex_decoder = lambda x: bytes.fromhex(x).decode('utf-8')
        prefixes = encode_to_hex(dir_names=dir_names)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_names[0])
        self.assertEqual(response.status_code, 204)
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_names[1], prefixes[0])
        self.assertEqual(response.status_code, 204)

        # 1.2 delete nested directory
        self.client.delete(TEST_BUCKET_1, [prefixes[1]], prefixes[0])

        # 1.3 try to rename nested deleted directory
        res = self.client.get_list(TEST_BUCKET_1, prefixes[0])
        pprint(res.json())
        pseudo_dir = dir_names[0]
        self.assertEqual(res.json()['dirs'], [])

        dst_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, dir_names[0], prefixes[0])
        self.assertEqual(res.status_code, 400)

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [prefixes[0]])

    def test_negative_case4(self):
        """
        # To make sure error returned in the following cases:
        # * rename directory to the name of existing file
        # * rename file to the name of existing directory
        """
        # 1. Upload a file and create a directory
        dir_name = generate_random_name()
        dir_name_prefix = encode_to_hex(dir_name)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']
        orig_name = res["orig_name"]

        # 2.1 Try rename directory to the name of existing file
        res = self.client.rename(TEST_BUCKET_1, dir_name_prefix, orig_name)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 29})  # "29": "Object exists already.",

        # 2.2 Try rename file to the name of existing directory
        res = self.client.rename(TEST_BUCKET_1, object_key, dir_name)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 10})  # "10": "Directory exists already.",

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [dir_name_prefix, object_key])

    def test_negative_case5(self):
        """
        # 1. rename file
        # 2. create directory with the same name
        # 3. make sure error appears
        """
        # 1. Upload file
        fn = "20180111_165127.jpg"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        # 2. Rename it
        random_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, object_key, random_name)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()['orig_name'], random_name)

        # 3. Create directory with the same name
        dir_name = random_name
        res = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 29})  # "29": "Object exists already.",

        # Clean: delete all created
        res = self.client.get_list(TEST_BUCKET_1)
        for el in res.json()['list']:
            if el['orig_name'] == random_name:
                object_key = el['object_key']
                break
        else:
            raise Exception('File gone somewhere')

        self.client.delete(TEST_BUCKET_1, [object_key])

    def test_negative_case6(self):
        """
        # 1. rename file to the same name but with different case ( uppercase / lowercase )
        # 2. to make sure no server call made
        """
        # 1. Upload 2 files with upper and lowercase names
        fn1 = "requirements.txt"
        fn2 = "README.md"
        res = self.client.upload(TEST_BUCKET_1, fn1)
        object_key1 = res['object_key']
        orig_name1 = res["orig_name"]
        res = self.client.upload(TEST_BUCKET_1, fn2)
        object_key2 = res['object_key']
        orig_name2 = res["orig_name"]

        # 2.1 Try rename file 1 to the same name lowercase -> uppercase
        res = self.client.rename(TEST_BUCKET_1, object_key1, orig_name1.upper())
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 29})  # "29": "Object exists already.",

        # 2.2 Try rename file 2 to the same name uppercase -> lowercase
        res = self.client.rename(TEST_BUCKET_1, object_key2, orig_name2.lower())
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 29})

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [object_key1, object_key2])

    def test_negative_case7(self):
        """
        # 1. to create directory on client in UPPERCASE when LOWERCASE exists on server
        # 2. to make sure files put in NTFS directory uploaded to remote dir using server name,
        #    not client name.
        """
        # 1.1 Create directory on lowercase
        dir_name_lower = generate_random_name().lower()
        dir_prefix = encode_to_hex(dir_name_lower)
        self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name_lower)

        # 1.2 Create directory on same but uppercase
        dir_name_upper = dir_name_lower.upper()
        res = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name_upper)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 10})

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [dir_prefix])

        # 2.1 Upload a file in lowercase, and try to upload same file with new version in uppercase
        fn = "requirements.txt"
        res = self.client.upload(TEST_BUCKET_1, fn)
        version = res['version']

        fn2 = 'requirements.txt'
        res = self.client.upload(TEST_BUCKET_1, fn2, last_seen_version=version)
        self.assertEqual(res['orig_name'], fn2)
        self.assertNotEqual(version, res['version'])

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [res['object_key']])

    def test_negative_case8(self):
        """
        # 1. to lock file
        # 2. to rename it from other user2
        # 3. make sure it is not renamed
        """

        # 1. Upload a file
        fn = '246x0w.png'
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        # 2. Lock uploaded file
        res = self.client.patch(TEST_BUCKET_1, 'lock', [object_key])
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()[0]['is_locked'], True)

        # 3. Try to rename uploaded locked file from user2
        self.client.login(USERNAME_2, PASSWORD_2)
        random_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, object_key, random_name)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {'error': 43})  # "43": "Locked",

        # Clean: delete all created
        self.client.login(USERNAME_1, PASSWORD_1)
        res = self.client.patch(TEST_BUCKET_1, 'unlock', [object_key])
        self.client.delete(TEST_BUCKET_1, [object_key])

    def test_negative_case9(self):
        """
        # 1. to upload two files
        # 2. to lock second file
        # 3. to rename one of them to the name of the second one
        # 4. to make sure rename is not allowed
        """

        # 1. Upload 2 files
        fn1 = '246x0w.png'
        res = self.client.upload(TEST_BUCKET_1, fn1)
        obj_key1 = res['object_key']
        fn2 = 'requirements.txt'
        res = self.client.upload(TEST_BUCKET_1, fn2)
        obj_key2 = res['object_key']

        # 2. Lock second uploaded file
        self.client.patch(TEST_BUCKET_1, 'lock', [obj_key2])

        # 3. Rename first file to name of second
        res = self.client.rename(TEST_BUCKET_1, obj_key1, fn2)
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json(), {"error": 29})  # "29": "Object exists already.",

        # Clean: delete all created
        self.client.patch(TEST_BUCKET_1, 'unlock', [obj_key2])
        self.client.delete(TEST_BUCKET_1, [obj_key1, obj_key2])

    def test_negative_case10(self):
        """
        # 1. upload file
        # 2. rename it
        # 3. rename it to its key
        # 4. file should not disappear
        """
        # 1. Upload file
        fn = '246x0w.png'
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key = res['object_key']

        # 2. Rename uploaded file
        random_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, object_key, random_name)
        orig_name = res.json()['orig_name']

        # 3. Try rename renamed file to its object key
        res = self.client.get_list(TEST_BUCKET_1)
        for el in res.json()['list']:
            if el['orig_name'] == orig_name:
                object_key2 = el['object_key']
                break
        else:
            raise Exception('Uploaded renamed file gone somewhere')

        res = self.client.rename(TEST_BUCKET_1, object_key2, object_key2)
        # print(res)
        # print(res.json())

        # 4. Check for file is not disapeared
        res = self.client.get_list(TEST_BUCKET_1)
        for el in res.json()['list']:
            if el['orig_name'] == object_key2:
                obj = el
                object_key3 = el['object_key']
                break
        self.assertEqual(obj['orig_name'], object_key2)

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [object_key3, object_key2])

    def test_negative_case11(self):
        """
        # 1. rename object to the key that exists in destination directory
        # 2. move to the destination directory
        # 3. previous object, with different orig name, should not be replaced
        """
        # 1 Upload a file
        fn = "246x0w.png"
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key1 = res["object_key"]
        orig_name1 = res["orig_name"]

        # 2 Upload another one
        res = self.client.upload(TEST_BUCKET_1, fn)
        object_key2 = res["object_key"]
        orig_name2 = res["orig_name"]

        # 3 Check for first file is not replaced and a second file created
        res = self.client.get_list(TEST_BUCKET_1)
        files = 0
        for el in res.json()['list']:
            if el['orig_name'] == orig_name1:
                files += 1
            if el['orig_name'] == orig_name2:
                files += 1
        self.assertEqual(files, 2)

        # Clean: delete all created
        self.client.delete(TEST_BUCKET_1, [object_key1, object_key2])

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

        # 2. Rename file
        random_name = generate_random_name()
        res = self.client.rename(TEST_BUCKET_1, object_key, random_name)
        self.assertEqual(res.status_code, 200)
        self.assertEqual(res.json()['orig_name'], random_name)

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

        keys = [(i['prefix'], i['key']) for i in result]
        assert ('', encode_to_hex(another_random_new_name)[:-1]) in keys
        assert (encode_to_hex(another_random_new_name), encode_to_hex(random_new_name)[:-1]) in keys
        assert ("{}{}".format(encode_to_hex(another_random_new_name), encode_to_hex(random_new_name)), object_key)

if __name__ == '__main__':
    unittest.main()
