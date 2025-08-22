sudo apt update
sudo apt install -y golang-go
go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
echo "export PATH=\$PATH:$(go env GOPATH)/bin" | sudo tee /etc/profile.d/go-path.sh >/dev/null
source /etc/profile.d/go-path.sh
which grpcurl
grpcurl --version
echo "✅ grpcurl installed successfully!"