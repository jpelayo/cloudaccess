// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/pem"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/crypto/ssh"
)

// startSFTPForKey is a server that only lets one key in.
func startSFTPForKey(t *testing.T, folder string, allowed ssh.PublicKey) driveConfig {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{
		PublicKeyCallback: func(_ ssh.ConnMetadata, offered ssh.PublicKey) (*ssh.Permissions, error) {
			if !bytes.Equal(offered.Marshal(), allowed.Marshal()) {
				return nil, errors.New("wrong key")
			}
			return nil, nil
		},
	}
	config.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go serveSFTP(connection, config, folder)
		}
	}()
	address := listener.Addr().(*net.TCPAddr)
	return driveConfig{
		Kind: "sftp", Host: "127.0.0.1", Port: address.Port, User: "tester", RootPath: folder,
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))),
	}
}

func TestEveryKindOfPrivateKeySignsIn(t *testing.T) {
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	ecdsaKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, edKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	for name, key := range map[string]crypto.PrivateKey{"RSA": rsaKey, "ECDSA": ecdsaKey, "ED25519": edKey} {
		for _, passphrase := range []string{"", "a key passphrase"} {
			label := name + " plain"
			if passphrase != "" {
				label = name + " encrypted"
			}
			t.Run(label, func(t *testing.T) {
				signer, err := ssh.NewSignerFromKey(key)
				if err != nil {
					t.Fatal(err)
				}
				var block *pem.Block
				if passphrase == "" {
					block, err = ssh.MarshalPrivateKey(key, "")
				} else {
					block, err = ssh.MarshalPrivateKeyWithPassphrase(key, "", []byte(passphrase))
				}
				if err != nil {
					t.Fatal(err)
				}
				config := startSFTPForKey(t, t.TempDir(), signer.PublicKey())
				config.KeyPEM = string(pem.EncodeToMemory(block))
				config.KeyPassphrase = passphrase

				d := openSFTP(t, config)
				var counter atomic.Int64
				if _, err := d.save(context.Background(), writeLocal(t, []byte("hello")), "a.txt", "", &counter); err != nil {
					t.Fatalf("a save with this key failed: %v", err)
				}
				items, err := d.list(context.Background(), "")
				if err != nil || len(items) != 1 {
					t.Fatalf("listing: %v %v", items, err)
				}
			})
		}
	}
}

func TestAWrongKeyPassphraseSaysSo(t *testing.T) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	block, err := ssh.MarshalPrivateKeyWithPassphrase(key, "", []byte("right"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = sftpAuthMethods(driveConfig{KeyPEM: string(pem.EncodeToMemory(block)), KeyPassphrase: "wrong"})
	if err == nil {
		t.Fatal("a wrong passphrase should fail")
	}
}

func TestAChangedHostKeyIsRefusedAndCanBeCompared(t *testing.T) {
	config := startSFTP(t, t.TempDir())
	offered, err := probeHostKey(context.Background(), config.Host, config.Port)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := keyFingerprint(config.HostKey)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Fingerprint != offered.Fingerprint {
		t.Fatalf("the same key should have one fingerprint: %v %v", saved, offered)
	}

	_, other, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(other)
	if err != nil {
		t.Fatal(err)
	}
	config.HostKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
	secure, err := newSFTPServer(config)
	if err != nil {
		t.Fatal(err)
	}
	_, err = secure.connect(context.Background())
	if got := classify(err).Kind; got != "hostKeyChanged" {
		t.Fatalf("expected a changed key, got %q: %v", got, err)
	}
	if different, _ := keyFingerprint(config.HostKey); different.Fingerprint == offered.Fingerprint {
		t.Fatal("two keys shouldn't share a fingerprint")
	}
}
