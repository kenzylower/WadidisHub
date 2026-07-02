const express = require("express");
const fs = require("fs");
const path = require("path");

const app = express();
const PORT = process.env.PORT || 3000;

app.get("/", (req, res) => {
    const scriptPath = path.join(__dirname, "script.lua");

    fs.readFile(scriptPath, "utf8", (err, data) => {
        if (err) {
            return res.status(500).send("Failed to load script.");
        }

        res.setHeader("Content-Type", "text/plain");
        res.send(data);
    });
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});