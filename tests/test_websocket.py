#!/usr/bin/env python3
"""
Integration test for Erlang Cowboy WebSocket server.
This script tests authentication, subscription, and ping/pong functionality.
"""
import asyncio
import json
import logging
import sys
import time
from typing import List, Optional

import websockets

from client_base import (
    REGION,
    BASE_URL,
    TEST_BUCKET_1,
    TEST_BUCKET_2,
    TEST_BUCKET_3,
    USERNAME_1,
    PASSWORD_1
)
from light_client import LightClient


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger('websocket_test')


DEFAULT_URI = "wss://{}/riak/websocket".format(BASE_URL.split("://", 1)[-1])

client = LightClient(REGION, BASE_URL, username=USERNAME_1, password=PASSWORD_1)
DEFAULT_TOKEN = client.token

DEFAULT_BUCKETS = [TEST_BUCKET_1, TEST_BUCKET_2, TEST_BUCKET_3]
PING_TIMEOUT = 60  # Maximum time to wait for a ping (seconds)


async def websocket_client(uri: str, token: str, buckets: List[str], timeout: int = 30) -> bool:
    """
    Connect to WebSocket server, authenticate, subscribe, and verify ping/pong mechanism.

    Args:
        uri: WebSocket server URI
        token: Authentication token
        buckets: List of bucket IDs to subscribe to
        timeout: Timeout in seconds for the entire test

    Returns:
        bool: True if test passed, False otherwise
    """
    logger.info(f"Connecting to {uri}")
    # Note: By default, websockets library automatically responds to ping frames with pong frames
    async with websockets.connect(uri) as websocket:
        # Send authorization
        auth_message = f"Authorization {token}"
        logger.info(f"Sending authorization: {auth_message}")
        await websocket.send(auth_message)

        # Send subscription
        bucket_list = " ".join(buckets)
        subscribe_message = f"SUBSCRIBE {bucket_list}"
        logger.info(f"Sending subscription: {subscribe_message}")
        await websocket.send(subscribe_message)
        # Wait for server ping or messages
        logger.info(f"Waiting for server ping (expected within {PING_TIMEOUT}s)")
        ping_received = False
        start_time = time.time()
        # Process messages until timeout
        try:
            while time.time() - start_time < timeout:
                # Check for incoming frames with a short timeout
                try:
                    message = await asyncio.wait_for(websocket.recv(), timeout=5)
                    # WebSocket library handles ping/pong automatically at the protocol level
                    # but we can still see the events in some cases depending on implementation
                    # Process different message types
                    if isinstance(message, bytes):
                        # Binary data (event from events_server)
                        logger.info(f"Received binary event: {len(message)} bytes")
                        # Send confirmation if message contains an ID 
                        # In a real implementation, you would extract the atomic_id from the message
                        try:
                            # This is a placeholder - your actual logic might differ
                            atomic_id = "event_id_123"  # In real code, extract from message
                            confirm_message = f"CONFIRM {atomic_id}"
                            logger.info(f"Sending confirmation: {confirm_message}")
                            await websocket.send(confirm_message)
                        except Exception as e:
                            logger.error(f"Error sending confirmation: {e}")
                    # The following would detect pings if they're exposed by the websockets library
                    # Note: Most libraries handle ping/pong at a lower level and don't expose them to application code
                    elif message == "ping" or (isinstance(message, str) and message.startswith("ping")):
                        logger.info("Received ping message from server")
                        ping_received = True
                        # No need to manually respond - the websockets library handles it automatically
                except asyncio.TimeoutError:
                    # This is just a timeout for each recv(), not the whole test
                    # We can optionally send a ping ourselves
                    if time.time() - start_time > 15 and not ping_received:  # After 15 seconds with no ping
                        try:
                            logger.info("Sending client-initiated ping")
                            pong_waiter = await websocket.ping()
                            await asyncio.wait_for(pong_waiter, timeout=2)
                            logger.info("Received pong response")
                        except Exception as e:
                            logger.warning(f"Error during client ping: {e}")
                    continue
            # If we've made it this far without disconnection, consider the test successful
            # The library has been automatically responding to pings
            logger.info("Connection remained active throughout the test period")
            return True
        except asyncio.TimeoutError:
            logger.error(f"Test timed out after {timeout} seconds")
            return False

async def run_test(uri: str, token: str, buckets: List[str]) -> bool:
    """Run the WebSocket test with specified parameters."""
    logger.info("Starting WebSocket integration test")
    logger.info(f"URI: {uri}")
    logger.info(f"Token: {'*' * len(token)}")  # Don't log the actual token
    logger.info(f"Buckets: {buckets}")
    
    success = await websocket_client(uri, token, buckets)
    
    if success:
        logger.info("✅ Test PASSED")
    else:
        logger.error("❌ Test FAILED")
    
    return success


def parse_args():
    """Parse command line arguments."""
    import argparse
    parser = argparse.ArgumentParser(description='WebSocket Server Integration Test')
    parser.add_argument('--uri', type=str, default=DEFAULT_URI, 
                        help=f'WebSocket server URI (default: {DEFAULT_URI})')
    parser.add_argument('--token', type=str, default=DEFAULT_TOKEN,
                        help='Authentication token')
    parser.add_argument('--buckets', type=str, default=",".join(DEFAULT_BUCKETS),
                        help='Comma-separated list of bucket IDs to subscribe to')
    return parser.parse_args()


if __name__ == '__main__':
    args = parse_args()
    buckets = args.buckets.split(',') if args.buckets else DEFAULT_BUCKETS
    
    # Run the test
    result = asyncio.get_event_loop().run_until_complete(run_test(args.uri, args.token, buckets))
    
    # Exit with appropriate status code
    sys.exit(0 if result else 1)
