import unittest
import json
import requests
import os

from client_base import (
    TestClient,
    BASE_URL,
    USERNAME_1,
    PASSWORD_1,
    TEST_BUCKET_1,
    TEST_BUCKET_3,
    configure_boto3)
from light_client import LightClient, generate_random_name, encode_to_hex


class AdminAPITest(TestClient):

    def setUp(self):
        self.client = LightClient(BASE_URL, USERNAME_1, PASSWORD_1)
        self.user_id = self.client.user_id
        self.token = self.client.token
        self.resource = configure_boto3()

    def test_tenant_operations(self):
        api_key = os.getenv("ADMIN_API_KEY")

        name = generate_random_name()
        url = "{}/riak/admin/tenants/".format(BASE_URL)
        headers={"authorization": "Token {}".format(api_key)}
        data = {
            "name": name,
            "enabled": "true",
            "groups": "Test Case, Automation"
        }
        # test create
        response = requests.post(url, json=data, headers=headers)
        self.assertEqual(response.status_code, 200)
        data1 = response.json()
        assert 'id' in data1
        assert 'name' in data1
        assert 'enabled' in data1
        assert 'groups' in data1
        group_ids = [i['id'] for i in data1['groups']]
        assert 'testcase' in group_ids
        assert 'automation' in group_ids
        group_names = [i['name'] for i in data1['groups']]
        assert 'Test Case' in group_names
        assert 'Automation' in group_names

        tenant_id = data1['id']
        url = "{}{}/".format(url, tenant_id)
        # test retrieve operation
        response = requests.get(url, headers=headers)
        data2 = response.json()

        group_ids = [i['id'] for i in data2['groups']]
        assert 'testcase' in group_ids
        assert 'automation' in group_ids
        group_names = [i['name'] for i in data2['groups']]
        assert 'Test Case' in group_names
        assert 'Automation' in group_names

        self.assertEqual(data1['id'], data2['id'])
        self.assertEqual(data1['name'], data2['name'])
        self.assertEqual(data1['enabled'], data2['enabled'])

        # test delete
        response = requests.delete(url, headers=headers)
        self.assertEqual(response.status_code, 200)

    def test_user_operations(self):
        api_key = os.getenv("ADMIN_API_KEY")

        # assign new group to tenant
        bits = TEST_BUCKET_1.split("-")
        tenant_id = bits[1]

        # retrieve tenant details
        url = "{}/riak/admin/tenants/{}/".format(BASE_URL, tenant_id)
        headers = {"authorization": "Token {}".format(api_key)}
        response = requests.get(url, headers=headers)
        data = response.json()

        new_group_name = generate_random_name()
        groups_list = ", ".join([i['name'] for i in data['groups']] + [new_group_name])

        data = {
            "groups": groups_list
        }
        response = requests.patch(url, json=data, headers=headers)

        self.assertEqual(response.status_code, 200)
        data = response.json()
        tenant_id = data['id']

        # create test user
        name = generate_random_name()
        url = "{}/riak/admin/{}/users/".format(BASE_URL, tenant_id)
        headers = {"authorization": "Token {}".format(api_key)}
        username = generate_random_name()
        data = {
            "login": username,
            "tel": "1234567",
            "password": "blah",
            "name": username,
            "enabled": True,
            "staff": False
        }
        # test create
        response = requests.post(url, json=data, headers=headers)
        data1 = response.json()
        self.assertEqual(response.status_code, 200)
        assert 'id' in data1
        assert 'name' in data1
        assert 'tenant_id' in data1
        assert 'tenant_name' in data1
        assert 'tenant_enabled' in data1
        assert 'login' in data1
        assert 'tel' in data1
        assert 'enabled' in data1
        assert 'staff' in data1
        assert 'groups' in data1

        user_id = data1['id']

        # delete user
        url = "{}/riak/admin/{}/users/{}/".format(BASE_URL, tenant_id, user_id)
        response = requests.delete(url, headers=headers)
        self.assertEqual(response.status_code, 200)


if __name__ == "__main__":
    unittest.main()
