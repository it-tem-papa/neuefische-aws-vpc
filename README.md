# AWS CLI VPC Setup

## Project Overview
This project automates the setup of a secure AWS infrastructure that includes:
- A VPC with private and public subnets.
- EC2 instances with SSH access, one public and one private.
- A NAT gateway to allow internet access to the private instance.


## How to Clone and Launch the Project

1. Clone the repository:
    ```bash
    git clone git@github.com:it-tem-papa/neuefische-aws-vpc.git
    cd neuefische-aws-vpc
    ```

2. Install AWS CLI and configure your AWS credentials:
    ```bash
    aws configure
    ```

3. Run the script:
    ```bash
    chmod 744 generate_vpc.sh
    ./generate_vpc.sh
    ```
