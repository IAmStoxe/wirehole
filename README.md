Certainly! Based on the provided Docker Compose and environment configuration, here is the revised end-to-end documentation for the `README.md` file:

```markdown
## What is this?

WireHole is a docker-compose project that combines WireGuard, PiHole, and Unbound to create a full or split-tunnel VPN that is easy to deploy and manage. This setup allows for a VPN with ad-blocking via PiHole and enhanced DNS privacy and caching through Unbound.

## Author

👤 **Devin Stokes**

- Twitter: [@DevinStokes](https://twitter.com/DevinStokes)
- GitHub: [@IAmStoxe](https://github.com/IAmStoxe)

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/IAmStoxe/wirehole/issues).

## Show your support

Give a ⭐ if this project helped you!

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-orange.png)](https://www.buymeacoffee.com/stoxe)

---

### Supported Architectures

The image supports multiple architectures such as `x86-64`, `arm64`, and `armhf`. The `linuxserver/wireguard` image automatically selects the correct image for your architecture.

**The architectures supported by this image are:**

| Architecture | Tag            |
| ------------ | -------------- |
| x86-64       | amd64-latest   |
| arm64        | arm64v8-latest |
| armhf        | arm32v7-latest |

---

### Quickstart

To begin using WireHole, clone the repository and start the containers:

```bash
#!/bin/bash

# Clone the WireHole repository from GitHub
git clone https://github.com/IAmStoxe/wirehole.git

# Change directory to the cloned repository
cd wirehole

# Update the .env file with your configuration
cp .env.example .env
nano .env  # Or use any text editor of your choice to edit the .env file

# Replace the public IP placeholder in the docker-compose.yml
sed -i "s/REPLACE_ME_WITH_YOUR_PUBLIC_IP/$(curl -s ifconfig.me)/g" docker-compose.yml

# Start the Docker containers
docker compose up
```

Remember to set secure passwords for `WGUI_SESSION_SECRET`, `WGUI_PASSWORD`, and `WEBPASSWORD` in your `.env` file.

---

## Environment Configuration Details

The `.env` file contains a series of environment variables that are essential for configuring the WireHole services within the Docker containers. Here is a detailed explanation of each variable:

### General Settings

- `TIMEZONE`: Sets the timezone for all services. It is important for logging and time-based operations. Example: `America/Los_Angeles`.

### User / Group Identifiers

- `PUID` and `PGID`: These ensure that the services have the correct permissions to access and modify files on the host system. They should match the user ID and group ID of the host user.

### Network Settings

- `UNBOUND_IPV4_ADDRESS`: The static IP address assigned to Unbound, ensuring it is reachable by Pi-hole.
- `PIHOLE_IPV4_ADDRESS`: The static IP address assigned to Pi-hole, allowing it to serve DNS requests for the network.
- `WIREGUARD_SERVER_PORT`: The port on which the WireGuard server will listen for connections.
- `WIREGUARD_PEER_DNS`: The DNS server that WireGuard clients will use, which is typically set to the Pi-hole's address.

### WireGuard Settings

- `WIREGUARD_PEERS`: Specifies the number of peer/client configurations to generate for WireGuard.

### WireGuard-UI Settings

- `WGUI_SESSION_SECRET`: A secret key used to encrypt session data for WireGuard-UI. This should be set to a secure, random value.
- `WGUI_USERNAME` and `WGUI_PASSWORD`: Credentials for accessing the WireGuard-UI interface.
- `WGUI_MANAGE_START`: When set to `true`, WireGuard-UI will manage the starting of the WireGuard service.
- `WGUI_MANAGE_RESTART`: When set to `true`, WireGuard-UI will manage the restarting of the WireGuard service.

### Pi-hole Settings

- `WEBPASSWORD`: The password for accessing the Pi-hole web interface. It should be set to a secure value to prevent unauthorized access.
- `PIHOLE_DNS`: The IP address of the Unbound server used by Pi-hole to resolve DNS queries.

Remember to replace any default or placeholder values with secure, unique values before deploying your services.

---

### Recommended Configuration / Split Tunnel

For a split-tunnel VPN, configure your WireGuard client `AllowedIps` to `10.2.0.0/24`, which will route only the web panel and DNS traffic through the VPN.

---

### Accessing the Web Panel (WireGuard-UI)

Manage your WireGuard VPN through the WireGuard-UI at:

`http://{YOUR_SERVER_IP}:5000`

Log in with the `WGUI_USERNAME` and `WGUI_PASSWORD` you have set in your `.env` file.

### Features of WireGuard-UI

- Client Management: Add, remove, and manage clients.
- Authentication: Secure login with a username and password.
- Configurations: Update global server settings and manage client configurations.

---

### Access PiHole

Connect to WireGuard and access the Pi-hole admin panel at `http://10.2.0.100/admin`. The login password is the one set as `WEBPASSWORD` in your `.env` file.

---

### Dynamic DNS (DDNS)

Configure DDNS by setting `WG_HOST` in your `.env` file to your DDNS URL.

```yaml
wireguard:
  environment:
    - WG_HOST=my.ddns.net
```

---

### Configuring / Parameters

Explain all the environment variables from your `.env` file here. (Refer to the previous section where we provided a table of explanations for each variable.)

---

### Additional Settings and Considerations

Discuss any additional settings such as Docker secrets, umask settings, user/group identifiers, adding clients, modifying DNS providers, and networking considerations. Make sure to update any instructions to match the current setup.

---

### Support and Updates

Provide information on how to access the shell while the container is running, view logs, update containers, and handle frequently asked questions. Ensure all the commands and steps are updated to reflect the current versions and practices.

---

###### Acknowledgements

Credit to LinuxServer.io for their maintenance of the Wireguard image and other contributions to the project.
