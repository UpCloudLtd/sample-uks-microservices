package main

import (
	"encoding/json"
	"os"
	"time"
)

func logEvent(level, msg string, fields map[string]interface{}) {
	entry := map[string]interface{}{
		"ts":    time.Now().UTC().Format(time.RFC3339Nano),
		"level": level,
		"msg":   msg,
	}
	for k, v := range fields {
		entry[k] = v
	}
	enc := json.NewEncoder(os.Stdout)
	_ = enc.Encode(entry)
}

func logInfo(msg string, fields map[string]interface{}) {
	logEvent("info", msg, fields)
}

func logError(msg string, fields map[string]interface{}) {
	logEvent("error", msg, fields)
}
