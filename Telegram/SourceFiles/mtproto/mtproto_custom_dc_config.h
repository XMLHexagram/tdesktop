/*
This file is part of Telegram Desktop,
the official desktop application for the Telegram messaging service.

For license and copyright information please follow this link:
https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL
*/
#pragma once

namespace MTP {

struct CustomDcEndpoint {
	const char *ip = nullptr;
	int port = 0;
	bool ipv6 = false;
};

struct CustomDc {
	int id = 0;
	const CustomDcEndpoint *endpoints = nullptr;
	int endpointCount = 0;
	const char *rsaPublicKeyPem = nullptr;
};

struct CustomDcConfig {
	int defaultDcId = 0;
	const CustomDc *dcs = nullptr;
	int dcCount = 0;
};

// Provided by the translation unit that Telegram/build/custom_dc_config.py
// generates at configure time. Null when this build targets the standard
// Telegram network.
[[nodiscard]] const CustomDcConfig *CustomDcConfigData();

} // namespace MTP
