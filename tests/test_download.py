import os.path as op
import unittest
import zipfile

from client_base import (
    BASE_URL,
    TEST_BUCKET_1,
    USER_1_API_KEY,
    REGION,
    configure_boto3)

from light_client import LightClient


class UploadTest(unittest.TestCase):

    def setUp(self):
        self.client = LightClient(REGION, BASE_URL, api_key=USER_1_API_KEY)

        #self.purge_test_buckets()

    def test_small_download_success(self):
        dir_name = "test-dir"
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, dir_name)
        self.assertEqual(response.status_code, 204)

        prefix = dir_name.encode().hex()
        response = self.client.create_pseudo_directory(TEST_BUCKET_1, "nested-dir", prefix=prefix)
        self.assertEqual(response.status_code, 204)

        nested_dir_prefix = "{}/{}".format(prefix, "nested-dir".encode().hex())
        result = self.client.upload(TEST_BUCKET_1, "requirements.txt", prefix=nested_dir_prefix)
        self.assertEqual(result["orig_name"], "requirements.txt")

        for fn in ["README.md", "20180111_165127.jpg"]:
            result = self.client.upload(TEST_BUCKET_1, fn, prefix=prefix)
            self.assertEqual(result["orig_name"], fn)

        response = self.client.download_zip(TEST_BUCKET_1, prefix)
        self.assertEqual(response.status_code, 200)
        with open("output/out.zip", "wb") as fd:
            fd.write(response.content)

        with zipfile.ZipFile("output/out.zip", 'r') as zip_ref:
            zip_ref.extractall("output")

        self.assertTrue(op.isdir("output/test-dir"))
        self.assertTrue(op.isdir("output/test-dir/nested-dir"))

        self.assertTrue(op.isfile("output/test-dir/{}".format("20180111_165127.jpg")))
        self.assertTrue(op.isfile("output/test-dir/{}".format("README.md")))
        self.assertTrue(op.isfile("output/test-dir/nested-dir/requirements.txt"))


if __name__ == '__main__':
    unittest.main()
