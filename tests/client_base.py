# -*- coding: utf-8 -*-

import logging
import json
import os
import io
import unittest
import xml.etree.ElementTree as ET
import tempfile
import sqlite3
from base64 import b64encode
import hashlib
import string
import random
import codecs

from environs import Env

from dvvset import DVVSet

import requests
import boto3
from botocore.config import Config
from botocore.utils import fix_s3_host
from botocore.exceptions import ClientError

env = Env()
env.read_env('.env')

logger = logging.getLogger(__name__)  # pylint: disable=invalid-name
for boto3_component in ['botocore', 's3transfer', 'boto3', 'boto']:
    logging.getLogger(boto3_component).setLevel(logging.INFO)

BASE_URL = env.str("BASE_URL", "https://lightup.cloud")
USERNAME_1 = env.str("USERNAME_1")
PASSWORD_1 = env.str("PASSWORD_1")
USERNAME_2 = env.str("USERNAME_2")
PASSWORD_2 = env.str("PASSWORD_2")
TEST_BUCKET_1 = env.str("TEST_BUCKET_1")
TEST_BUCKET_2 = env.str("TEST_BUCKET_2")
TEST_BUCKET_3 = env.str("TEST_BUCKET_3")
UPLOADS_BUCKET_NAME = env.str("UPLOADS_BUCKET_NAME")
ACTION_LOG_FILENAME = env.str("ACTION_LOG_FILENAME")
ADMIN_API_KEY = env.str("ADMIN_API_KEY")
USER_1_API_KEY = env.str("USER_1_API_KEY")
REGION = env.str("REGION")

ACCESS_KEY = env.str("ACCESS_KEY")
SECRET_KEY = env.str("SECRET_KEY")
HTTP_PROXY = env.str("HTTP_PROXY")  # if connection hangs, make sure proxy port is corret

RIAK_DB_VERSION_KEY = ".luc"

FILE_UPLOAD_CHUNK_SIZE = 2000000


def configure_boto3():
    session = boto3.Session(
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
    )
    config = Config(proxies={"http": HTTP_PROXY},
                    s3={"addressing_style": "path"})
    resource = session.resource("s3", config=config, use_ssl=False)
    resource.meta.client.meta.events.unregister("before-sign.s3", fix_s3_host)
    # boto3.set_stream_logger("botocore")
    return resource


def generate_random_name():
    """
    Returns a random name of weird characters.
    """
    alphabet = "{}{}ЄєІіЇїҐґ".format(string.digits, string.ascii_lowercase)
    return "".join(random.sample(alphabet, 20))


def encode_to_hex(dir_name: str = None, dir_names: list = None):
    """
    Encodes directory name to hex format, as server expects.
    """
    if dir_name:
        return dir_name.encode().hex() + "/"
    if dir_names:
        result = [name.encode().hex() + "/" for name in dir_names]
        return result
    return False


def decode_from_hex(hex_encoded_str):
    """
    Decodes hex directory name
    """
    decode_hex = codecs.getdecoder("hex_codec")
    return decode_hex(hex_encoded_str)[0].decode("utf-8")


class TestClient(unittest.TestCase):
    def setUp(self):
        creds = {"login": USERNAME_1, "password": PASSWORD_1}
        response = requests.post("{}/riak/login".format(BASE_URL), data=json.dumps(creds), verify=False,
                                 headers={"content-type": "application/json"})
        data = response.json()
        self.token = data["token"]
        self.user_id = data["id"]
        self.resource = configure_boto3()
        self.purge_test_buckets()

    def get_default_headers(self):
        return {
            "authorization": "Token {}".format(self.token),
            "content-type": "application/json"
        }

    def get_all_headers(self, headers):
        headers = headers or {}

        defaults = self.get_default_headers()
        defaults.update(headers)

        return defaults

    def get_json(self, url, status=200, **kwargs):
        headers = kwargs.pop('headers', {})
        headers = self.get_all_headers(headers)
        response = requests.get(url, headers=headers, **kwargs)
        self.assertEqual(response.status_code, status)
        response_content_type = response.headers.get("content-type")
        if response_content_type is not None:
            self.assertEqual(response_content_type, "application/json")
            return response.json()
        return response

    def post_json(self, url, data, status=200, **kwargs):
        headers = kwargs.pop('headers', {})
        headers = self.get_all_headers(headers)
        response = requests.post(url, data=json.dumps(data), headers=headers, timeout=3)
        self.assertEqual(response.status_code, status)
        return json.loads(response.content.decode("utf8"))

    def delete_json(self, url, data, status=200, **kwargs):
        headers = kwargs.pop('headers', {})
        headers = self.get_all_headers(headers)
        response = requests.delete(url, data=json.dumps(data), headers=headers, timeout=3)
        self.assertEqual(response.status_code, status)
        self.assertEqual(response.headers["content-type"], "application/json")
        return response.json()

    def upload_file(self, url, fn, prefix="", guid="",
                    last_seen_version=None, form_data=None, **kwargs):
        """
        Uploads file to server by splitting it to chunks and testing if server
        has chunk already, before actual upload.

        ``url`` -- The base upload API endpoint
        ``fn`` -- filename
        ``prefix`` -- an object"s prefix on server
        ``guid`` -- unique identifier ( UUID4 ) for tracking history of changes
        ``last_seen_version`` -- casual history value, generated by DVVSet()
        """
        stat = os.stat(fn)
        modified_utc = str(int(stat.st_mtime))
        size = stat.st_size
        if not last_seen_version:
            dvvset = DVVSet()
            dot = dvvset.create(dvvset.new(modified_utc), self.user_id)
            version = b64encode(json.dumps(dot).encode())
        else:
            # increment version
            context = dvvset.join(last_seen_version)
            new_dot = dvvset.update(dvvset.new_with_history(context, modified_utc),
                                    dot, self.user_id)
            version = dvvset.sync([last_seen_version, new_dot])
            version = b64encode(json.dumps(version)).encode()

        result = None
        with open(fn, "rb") as fd:
            _read_chunk = lambda: fd.read(FILE_UPLOAD_CHUNK_SIZE)
            part_num = 1
            md5_list = []
            upload_id = None
            offset = 0
            for chunk in iter(_read_chunk, ""):
                md5 = hashlib.md5(chunk)
                md5_digest = md5.hexdigest()
                md5_list.append(md5_digest)
                multipart_form_data = {
                    "files[]": (fn, ""),
                    "md5": md5_digest,
                    "prefix": prefix,
                    "guid": guid,
                    "version": version
                }
                chunk_size = len(chunk)
                if form_data:
                    multipart_form_data.update(form_data)
                if size > FILE_UPLOAD_CHUNK_SIZE:
                    offset = (part_num-1) * FILE_UPLOAD_CHUNK_SIZE
                    limit = offset+chunk_size-1
                    if limit < 0:
                        limit = 0
                    ct_range = "bytes {}-{}/{}".format(offset, limit, size)
                else:
                    ct_range = "bytes 0-{}/{}".format(size-1, size)
                headers = {
                    "accept": "application/json",
                    "authorization": "Token {}".format(self.token),
                    "content-range": ct_range
                }
                if part_num == 1:
                    r_url = url
                else:
                    r_url = "{}{}/{}/".format(url, upload_id, part_num)

                if offset+chunk_size == size:
                    # last chunk
                    etags = ",".join(["{},{}".format(i+1, md5_list[i]) for i in range(len(md5_list))])
                    multipart_form_data.update({
                        "etags[]": etags
                    })

                # send request without binary data first
                response = requests.post(r_url, files=multipart_form_data, headers=headers, timeout=3)
                if response.status_code == 206:
                    # skip chunk upload, as server has it aleady
                    response_json = response.json()
                    upload_id = response_json["upload_id"]
                    guid = response_json["guid"]
                    part_num += 1
                    if offset+chunk_size == size:
                        result = response_json
                        break
                    else:
                        continue
                self.assertEqual(response.status_code, 200)
                response_json = response.json()
                upload_id = response_json["upload_id"]
                guid = response_json["guid"] # server could change GUID
                server_md5 = response_json["md5"]
                self.assertEqual(md5_digest, server_md5)

                # upload an actual data now
                multipart_form_data.update({
                    "files[]": (fn, chunk),
                    "guid": guid  # GUID could change
                })
                response = requests.post(r_url, files=multipart_form_data, headers=headers, timeout=3)
                self.assertEqual(response.status_code, 200)
                response_json = response.json()
                if offset+chunk_size == size:
                    # the last chunk has been processed, expect complete_upload response
                    expected = set(["lock_user_tel", "lock_user_name", "guid", "upload_id",
                                    "lock_modified_utc", "lock_user_id", "is_locked",
                                    "author_tel", "is_deleted", "upload_time", "md5",
                                    "version", "height", "author_id", "author_name",
                                    "object_key", "bytes", "width", "orig_name", "end_byte"])
                    self.assertEqual(expected, set(response_json.keys()))
                    result = response_json
                    break
                else:
                    self.assertEqual(set(["end_byte", "upload_id", "guid", "upload_id", "md5"]),
                                     set(response_json.keys()))
                    #self.assertEqual(response_json["guid"], guid)
                    #self.assertEqual(response_json["upload_id"], upload_id)
                    server_md5 = response_json["md5"]
                    self.assertEqual(md5_digest, server_md5)
                    upload_id = response_json["upload_id"]
                    part_num += 1
        return result

    def upload_thumbnail(self, url, fn, object_key, prefix="", form_data=None):
        """
        Uploads thumbnail to server

        ``url`` -- The base upload API endpoint
        ``object_key`` -- object key to upload thumbnail for
        ``fn`` -- thumbnail filename
        ``prefix`` -- an object"s prefix on server
        """
        data = {}
        result = None
        with open(fn, "rb") as fd:
            data = fd.read()
            md5 = hashlib.md5(data)
            md5_digest = md5.hexdigest()
            multipart_form_data = {
                "files[]": (fn, data),
                "md5": md5_digest,
                "prefix": prefix,
                "object_key": object_key
            }
            if form_data:
                multipart_form_data.update(form_data)

            headers = {
                "accept": "application/json",
                "authorization": "Token {}".format(self.token)
            }
            response = requests.post(url, files=multipart_form_data, headers=headers, timeout=5)
            self.assertEqual(response.status_code, 200)
            response_json = response.json()
            server_md5 = response_json["md5"]
            self.assertEqual(md5_digest, server_md5)
            result = response_json
        return result

    def download_object(self, bucketId, objectKey):
        """
        This method downloads aby object from the object storage.
        Unlike download_file, it queries Riak CS directly.
        """
        bucket = self.resource.Bucket(bucketId)
        content = io.BytesIO()
        bucket.download_fileobj(Fileobj=content, Key=objectKey)
        return content.getvalue()

    def download_file(self, bucketId, objectKey):
        """
        This method uses /riak/download/ API endpoint to download file
        """
        url = "{}/riak/download/{}/?object_key={}".format(BASE_URL, bucketId, objectKey)
        response = requests.get(url, headers={"authorization": "Token {}".format(self.token)})
        return response.status_code, response.content

    def download_zip_file(self, bucketId, prefix):
        """
        This method uses /riak/download-zip/ API endpoint to download archive with all files in directory.
        """
        url = "{}/riak/download-zip/{}".format(BASE_URL, bucketId, prefix)
        response = requests.get(url, headers={"authorization": "Token {}".format(self.token)})
        return response.status_code, response.content

    def head(self, bucketId, objectKey):
        obj = self.resource.Object(bucketId, objectKey)
        obj.load()
        return obj.metadata

    def remove_object(self, bucketId, objectKey):
        bucket = self.resource.Bucket(bucketId)
        bucket.Object(objectKey).delete()

    def _drop_bucket_objects(self, bucket_id):
        bucket = self.resource.Bucket(bucket_id)
        try:
            objects = [i for i in bucket.objects.all()]
        except self.resource.meta.client.exceptions.NoSuchBucket:
            objects = []
        for obj in objects:
            obj.delete()

    def purge_test_buckets(self):
        """
        Deletes all objects from bucket
        """
        self._drop_bucket_objects(TEST_BUCKET_1)
        self._drop_bucket_objects(TEST_BUCKET_2)
        self._drop_bucket_objects(TEST_BUCKET_3)
        self._drop_bucket_objects(UPLOADS_BUCKET_NAME)

    def parse_action_log(self, xmlstring):
        tree = ET.ElementTree(ET.fromstring(xmlstring))
        root = tree.getroot()
        record = root.find("record")
        action = record.find("action").text
        details = record.find("details").text
        user_name = record.find("user_name").text
        tenant_name = record.find("tenant_name").text
        return {
            "action": action,
            "details": details,
            "user_name": user_name,
            "tenant_name": tenant_name
        }

    def create_pseudo_directory(self, name, prefix=None):
        req_headers = {
            "content-type": "application/json",
            "authorization": "Token {}".format(self.token),
        }
        if prefix is None:
            prefix = ""
        data = {
            "prefix": prefix,
            "directory_name": name
        }
        url = "{}/riak/list/{}/".format(BASE_URL, TEST_BUCKET_1)
        return requests.post(url, json=data, headers=req_headers, timeout=3)

    def check_sql(self, bucketId, sql, *args, db_key=RIAK_DB_VERSION_KEY):
        """
        Download SQLite db and execute SQL
        """
        def dict_factory(cursor, row):
            fields = [column[0] for column in cursor.description]
            return {key: value for key, value in zip(fields, row)}

        try:
            dbcontent = self.download_object(bucketId, db_key)
        except ClientError:
            return []

        fn = tempfile.mktemp()
        with open(fn, "wb") as fd:
            fd.write(dbcontent)
        con = sqlite3.connect(fn)
        con.row_factory = dict_factory
        cur = con.cursor()
        cur.execute(sql, *args)
        result = cur.fetchall()
        con.close()
        os.unlink(fn)
        return result
