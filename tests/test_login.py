import unittest
import requests

from client_base import TestClient, BASE_URL, USERNAME_1, PASSWORD_1


class AuthTest(TestClient):

    def test_login_success(self):
        url = "{}/riak/login/".format(BASE_URL)
        data = {"login": USERNAME_1, "password": PASSWORD_1}
        response = self.post_json(url, data)
        keys = response.keys()
        self.assertEqual(set(keys), set(["id", "name", "tenant_id",
            "tenant_name", "tenant_enabled", "login", "tel", "enabled",
            "staff", "groups", "token"]))

    def test_login_fails(self):
        url = "{}/riak/login/".format(BASE_URL)
        data = {"login": USERNAME_1, "password": "incorrect"}
        response = self.post_json(url, data, status=403)
        self.assertEqual(response, {"error":3})

    def test_incorrect_json(self):
        url = "{}/riak/login/".format(BASE_URL)
        response = requests.post(url, data="something", timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"login": "vb@xentime.com", "password": None}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"login": "vb@xentime.com", "password": ""}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"login": None, "password": "pwd"}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"login": "", "password": "pwd"}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"password": "pwd"}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        data = {"login": "something"}
        response = requests.post(url, data=data, timeout=5,
                             headers={"content-type": "application/json"})
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.text, "{\"error\":21}")

        response = self.get_json(url, headers={"content-type": "application/json"}, status=405)


if __name__ == "__main__":
    unittest.main()
