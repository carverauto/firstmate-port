package fmsteer

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// ErrSignedOut indicates an expired or revoked authenticated session.
var ErrSignedOut = errors.New("not signed in (token expired or revoked); run fm-steer auth login")

// PostJSON POSTs a JSON body and decodes a JSON response, returning an
// error for any non-2xx status so a failed write is never mistaken for a
// successful one.
func PostJSON(url, token string, body any, out any) error {
	status, raw, err := requestJSON(http.MethodPost, url, token, body, out)
	if err != nil {
		return err
	}
	return statusError(status, raw)
}

// PostJSONStatus is PostJSON with the response status exposed and no
// status error, so callers can distinguish a meaningful non-2xx from a
// failure: authorization_pending (400) while polling for a device token,
// or an empty inbox on `inbox next`.
func PostJSONStatus(url, token string, body any, out any) (int, error) {
	status, _, err := requestJSON(http.MethodPost, url, token, body, out)
	if err != nil {
		return status, err
	}
	if status >= 500 {
		return status, fmt.Errorf("HTTP %d", status)
	}
	return status, nil
}

// GetJSON GETs a JSON document with an optional bearer token, erroring on
// a non-2xx status or on a 2xx body that is not JSON.
func GetJSON(url, token string, out any) error {
	status, raw, err := requestJSON(http.MethodGet, url, token, nil, out)
	if err != nil {
		return err
	}
	return statusError(status, raw)
}

// requestJSON performs the request and decodes the body, reporting a
// non-JSON body only when the status said the call succeeded.
func requestJSON(method, url, token string, body any, out any) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	req.Header.Set("user-agent", UserAgent)
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized && token != "" {
		return resp.StatusCode, nil, ErrSignedOut
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp.StatusCode, raw, fmt.Errorf("%s: response was not JSON: %w", url, err)
		}
	}
	return resp.StatusCode, raw, nil
}

// statusError turns a non-2xx status into an error, preferring the
// portal's own `error` field so the operator sees why.
func statusError(status int, raw []byte) error {
	if status >= 200 && status < 300 {
		return nil
	}
	var body struct {
		Error string `json:"error"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &body) == nil && body.Error != "" {
		return fmt.Errorf("HTTP %d: %s", status, body.Error)
	}
	return fmt.Errorf("HTTP %d", status)
}
