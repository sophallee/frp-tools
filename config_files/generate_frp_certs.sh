#!/bin/bash
script_file=$(basename "$0")
script_path=$(realpath "$0")
script_dir=$(dirname "$script_path")
script_name=$(echo $script_file | cut -d. -f 1)
cd $script_dir

# Configuration
properties_file="$script_dir/cert.properties"
ssl_dir="$script_dir/certs"
clients_dir="$ssl_dir/clients"  # New: directory for client certificates
clients_list_file="$script_dir/clients.list"
openssl_cnf="/etc/pki/tls/openssl.cnf"

# Function to load properties
load_properties() {
    if [ -f "$properties_file" ]; then
        source "$properties_file"
    else
        echo "Error: Properties file $properties_file not found!"
        exit 1
    fi
}

# Load properties
load_properties

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --generate ca-cert          Generate CA certificate only"
    echo "  --generate server-cert      Generate server certificate only"
    echo "  --generate client-cert      Generate client certificate for current host"
    echo "  --generate all-clients      Generate certificates for all clients in clients.list"
    echo "  --generate all              Generate all certificates (CA, server, all clients)"
    echo "  --verify                    Verify generated certificates"
    echo "  --help                      Show this help message"
    echo ""
    echo "Configuration files:"
    echo "  - Properties:    $properties_file"
    echo "  - Clients list:  $clients_list_file (one client per line)"
    echo "  - Output dir:    $ssl_dir"
    echo "  - Client certs:  $clients_dir/"
}

# Function to generate CA certificate
generate_ca_cert() {
    echo "Generating CA certificate..."
    
    mkdir -p "$ssl_dir"
    cd "$ssl_dir"
    
    # Copy OpenSSL config
    cp "$openssl_cnf" ./frs-openssl.cnf
    
    # Generate CA key and certificate
    openssl genrsa -out ca.key 2048
    openssl req -x509 -new -nodes -key ca.key \
        -subj "/CN=$ssl_ca_cn" \
        -days 5000 -out ca.crt
    
    echo "✓ CA certificate generated:"
    echo "  CN: $ssl_ca_cn"
    echo "  Files: ca.key, ca.crt"
}

# Function to generate server certificate
generate_server_cert() {
    echo "Generating server certificate..."
    
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate not found. Generate CA first."
        exit 1
    fi
    
    cd "$ssl_dir"
    
    # Generate server key and CSR
    openssl genrsa -out server.key 2048
    openssl req -new -sha256 -key server.key \
        -subj "/C=$ssl_country/ST=$ssl_state/L=$ssl_locality/O=$ssl_organization/CN=$ssl_server_cn" \
        -reqexts SAN \
        -config <(cat frs-openssl.cnf <(printf "\n[SAN]\nsubjectAltName=$ssl_server_sans")) \
        -out server.csr
    
    # Sign server certificate
    openssl x509 -req -days 3650 -sha256 \
        -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -extfile <(printf "subjectAltName=$ssl_server_sans") \
        -out server.crt
    
    # Clean up CSR
    rm -f server.csr ca.srl
    
    echo "✓ Server certificate generated:"
    echo "  CN: $ssl_server_cn"
    echo "  SANs: $ssl_server_sans"
    echo "  Files: server.key, server.crt"
}

# Function to generate client certificate
generate_client_cert() {
    local client_cn="$1"
    
    echo "Generating client certificate: $client_cn"
    
    # Ensure clients directory exists
    mkdir -p "$clients_dir"
    
    cd "$clients_dir"
    
    # Generate client key and CSR
    openssl genrsa -out "${client_cn}.key" 2048
    openssl req -new -sha256 -key "${client_cn}.key" \
        -subj "/C=$ssl_country/ST=$ssl_state/L=$ssl_locality/O=$ssl_organization/CN=$client_cn" \
        -reqexts SAN \
        -config <(cat "$ssl_dir/frs-openssl.cnf" <(printf "\n[SAN]\nsubjectAltName=DNS:$client_cn")) \
        -out "${client_cn}.csr"
    
    # Sign client certificate
    cd "$ssl_dir"
    openssl x509 -req -days 3650 -sha256 \
        -in "$clients_dir/${client_cn}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -extfile <(printf "subjectAltName=DNS:$client_cn") \
        -out "$clients_dir/${client_cn}.crt"
    
    # Create client certificate bundle (.pem) containing both cert and key
    cd "$clients_dir"
    cat "${client_cn}.crt" "${client_cn}.key" > "${client_cn}.pem"
    chmod 600 "${client_cn}.pem"
    
    # Clean up CSR
    rm -f "${client_cn}.csr" "$ssl_dir/ca.srl"
    
    echo "  ✓ Client certificate generated in $clients_dir/:"
    echo "    - ${client_cn}.key (private key)"
    echo "    - ${client_cn}.crt (certificate)"
    echo "    - ${client_cn}.pem (bundle)"
}

# Function to generate certificate for current host
generate_current_client_cert() {
    local client_cn="${ssl_client_cn:-$(hostname -f)}"
    
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate not found. Generate CA first."
        exit 1
    fi
    
    generate_client_cert "$client_cn"
}

# Function to generate certificates for all clients in list
generate_all_client_certs() {
    if [ ! -f "$ssl_dir/ca.crt" ] || [ ! -f "$ssl_dir/ca.key" ]; then
        echo "Error: CA certificate not found. Generate CA first."
        exit 1
    fi
    
    if [ ! -f "$clients_list_file" ]; then
        echo "Error: Clients list file not found: $clients_list_file"
        exit 1
    fi
    
    echo "Generating certificates for clients in $clients_list_file..."
    echo "Client certificates will be stored in: $clients_dir"
    
    local count=0
    
    # Read clients from file
    while IFS= read -r client_cn || [ -n "$client_cn" ]; do
        # Skip empty lines and comments
        client_cn=$(echo "$client_cn" | xargs)
        if [ -z "$client_cn" ] || [[ "$client_cn" =~ ^# ]]; then
            continue
        fi
        
        generate_client_cert "$client_cn"
        ((count++))
    done < "$clients_list_file"
    
    echo ""
    echo "✓ Generated $count client certificates in $clients_dir"
}

# Function to generate all certificates
generate_all_certs() {
    echo "Generating all certificates..."
    echo "Output directory: $ssl_dir"
    echo "Client certificates directory: $clients_dir"
    
    mkdir -p "$ssl_dir"
    mkdir -p "$clients_dir"
    
    generate_ca_cert
    echo ""
    generate_server_cert
    echo ""
    
    if [ -f "$clients_list_file" ]; then
        generate_all_client_certs
    else
        echo "Note: No clients.list file found. Skipping client certificates."
        echo "Create $clients_list_file with client hostnames (one per line) to generate client certs."
    fi
    
    echo ""
    echo "Certificate structure:"
    echo "  $ssl_dir/ca.crt           - CA certificate"
    echo "  $ssl_dir/server.crt       - Server certificate"
    echo "  $clients_dir/*.crt        - Client certificates"
    echo "  $clients_dir/*.pem        - Client certificate bundles"
}

# Function to verify certificates
verify_certs() {
    if [ ! -d "$ssl_dir" ]; then
        echo "Error: Certs directory not found: $ssl_dir"
        exit 1
    fi
    
    echo "Verifying certificates..."
    echo "========================="
    
    # Verify CA
    if [ -f "$ssl_dir/ca.crt" ]; then
        echo "CA Certificate:"
        openssl x509 -in "$ssl_dir/ca.crt" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"
        echo ""
    else
        echo "✗ CA certificate not found"
    fi
    
    # Verify server certificate
    if [ -f "$ssl_dir/server.crt" ]; then
        echo "Server Certificate:"
        openssl x509 -in "$ssl_dir/server.crt" -text -noout | grep -E "Subject:|Issuer:|Not Before|Not After"
        
        # Check against CA
        if openssl verify -CAfile "$ssl_dir/ca.crt" "$ssl_dir/server.crt" > /dev/null 2>&1; then
            echo "  ✓ Valid (signed by CA)"
        else
            echo "  ✗ Invalid"
        fi
        echo ""
    else
        echo "✗ Server certificate not found"
    fi
    
    # Verify client certificates
    echo "Client Certificates in $clients_dir/:"
    local client_count=0
    
    if [ -d "$clients_dir" ]; then
        cd "$clients_dir"
        
        for cert_file in *.crt; do
            if [ -f "$cert_file" ]; then
                client_name="${cert_file%.crt}"
                if openssl verify -CAfile "$ssl_dir/ca.crt" "$cert_file" > /dev/null 2>&1; then
                    echo "  ✓ $client_name"
                    ((client_count++))
                else
                    echo "  ✗ $client_name (invalid)"
                fi
            fi
        done
        
        if [ $client_count -eq 0 ]; then
            echo "  No client certificates found"
        else
            echo ""
            echo "Total: $client_count valid client certificate(s)"
        fi
    else
        echo "  Client directory not found: $clients_dir"
    fi
    
    # Check if .pem bundles exist
    if [ -d "$clients_dir" ]; then
        local pem_count=0
        for pem_file in "$clients_dir"/*.pem; do
            if [ -f "$pem_file" ]; then
                ((pem_count++))
            fi
        done
        
        if [ $pem_count -gt 0 ]; then
            echo ""
            echo "Found $pem_count client certificate bundle(s) (.pem files)"
        fi
    fi
}

# Main script logic
case "${1:-}" in
    --generate)
        case "${2:-}" in
            ca-cert)
                generate_ca_cert
                ;;
            server-cert)
                generate_server_cert
                ;;
            client-cert)
                generate_current_client_cert
                ;;
            all-clients)
                generate_all_client_certs
                ;;
            all|"")
                generate_all_certs
                ;;
            *)
                echo "Error: Unknown certificate type '$2'"
                echo "Valid types: ca-cert, server-cert, client-cert, all-clients, all"
                exit 1
                ;;
        esac
        ;;
    --verify|-v)
        verify_certs
        ;;
    --help|-h|"")
        show_usage
        ;;
    *)
        echo "Error: Unknown option '$1'"
        show_usage
        exit 1
        ;;
esac