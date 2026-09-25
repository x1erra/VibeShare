package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func doctor(c *client, jsonOut bool) error {
	result := map[string]any{"appPath": "/Applications/VibeShare.app", "appInstalled": false,
		"routerReachable": false, "providerReachable": false, "stateDir": stateDir()}
	if st, err := os.Stat(result["appPath"].(string)); err == nil && st.IsDir() {
		result["appInstalled"] = true
	}
	if status, _, err := c.get("/api/status"); err == nil {
		result["routerReachable"] = true
		result["version"] = status["version"]
		if up, ok := status["upstream"].(map[string]any); ok {
			result["providerReachable"] = up["reachable"] == true
		}
	} else {
		result["routerError"] = err.Error()
	}
	if jsonOut {
		return printJSON(result)
	}
	fmt.Printf("app installed: %v\nrouter reachable: %v\nprovider reachable: %v\nstate: %s\n",
		result["appInstalled"], result["routerReachable"], result["providerReachable"], result["stateDir"])
	if err, ok := result["routerError"]; ok {
		fmt.Printf("router: %v\n", err)
	}
	return nil
}

func listModels(c *client, jsonOut bool) error {
	st, _, err := c.get("/api/status")
	if err != nil {
		return err
	}
	port := 8788
	if v, ok := st["frontPort"].(float64); ok && v > 0 {
		port = int(v)
	}
	front := &client{base: "http://127.0.0.1:" + strconv.Itoa(port), http: &http.Client{Timeout: 10 * time.Second}}
	raw, err := front.do("GET", "/v1/models", nil)
	if err != nil {
		return err
	}
	if jsonOut {
		_, err = os.Stdout.Write(append(raw, '\n'))
		return err
	}
	var body struct {
		Data []struct {
			ID      string `json:"id"`
			OwnedBy string `json:"owned_by"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return err
	}
	for _, model := range body.Data {
		fmt.Printf("%-44s %s\n", model.ID, model.OwnedBy)
	}
	return nil
}

func showLogs(args []string, jsonOut bool) error {
	if len(args) > 1 {
		return errors.New("usage: vibeshare logs [router|provider|login-<provider>]")
	}
	if len(args) == 0 {
		if jsonOut {
			return printJSON(map[string]any{"directory": stateDir(), "names": []string{"router", "provider", "login-<provider>"}})
		}
		fmt.Printf("logs in %s\n  router\n  provider\n  login-<provider>\n", stateDir())
		return nil
	}
	name := args[0]
	file := ""
	switch name {
	case "router":
		file = "router.log"
	case "provider":
		file = "cli-proxy.log"
	default:
		if strings.HasPrefix(name, "login-") {
			if _, err := findProvider(strings.TrimPrefix(name, "login-")); err == nil {
				file = name + ".log"
			}
		}
	}
	if file == "" {
		return errors.New("unknown log (use router, provider, or login-<provider>)")
	}
	path := filepath.Join(stateDir(), file)
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 128<<10 {
		if _, err := f.Seek(-(128 << 10), 2); err != nil {
			return err
		}
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) > 50 {
		lines = lines[len(lines)-50:]
	}
	if jsonOut {
		return printJSON(map[string]any{"path": path, "lines": lines})
	}
	fmt.Println(strings.Join(lines, "\n"))
	return nil
}

func cmdApp(args []string, jsonOut bool) error {
	if len(args) == 0 {
		return errors.New("usage: vibeshare app open|quit|restart [--yes]")
	}
	if args[0] != "open" && ((args[0] != "quit" && args[0] != "restart") || len(args) != 2 || args[1] != "--yes") {
		return errors.New("usage: vibeshare app quit|restart --yes (disconnects active friends)")
	}
	if args[0] == "open" && len(args) != 1 {
		return errors.New("usage: vibeshare app open")
	}
	app := "/Applications/VibeShare.app"
	if _, err := os.Stat(app); err != nil {
		return fmt.Errorf("installed app missing: %w", err)
	}
	if args[0] == "open" && len(args) == 1 {
		if err := exec.Command("open", app).Run(); err != nil {
			return err
		}
		if jsonOut {
			return printJSON(map[string]any{"ok": true, "action": "open"})
		}
		fmt.Println("opened VibeShare")
		return nil
	}
	if err := exec.Command("osascript", "-e", `tell application id "com.vibeshare.app" to quit`).Run(); err != nil {
		return err
	}
	if args[0] == "restart" {
		for i := 0; i < 40; i++ {
			if exec.Command("pgrep", "-x", "VibeShare").Run() != nil {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if exec.Command("pgrep", "-x", "VibeShare").Run() == nil {
			return errors.New("app did not quit; refusing to launch over the old process")
		}
		if err := exec.Command("open", app).Run(); err != nil {
			return err
		}
	}
	if jsonOut {
		return printJSON(map[string]any{"ok": true, "action": args[0]})
	}
	fmt.Println(args[0] + " requested")
	return nil
}
