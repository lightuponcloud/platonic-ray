from light_client import LightClient

BASE_URL="https://lightup.cloud"
USER_1_API_KEY="8374808e-bf79-44ab-a674-16b676ac4c3b"

client = LightClient("US", BASE_URL, api_key=USER_1_API_KEY)
path = "the-integrationtests-integration1-res/70686f746f73"
res = client.calculate_url_signature("GET", path, "")
print(res)
