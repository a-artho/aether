#include "sha.h"
#include "base64.h"
#include <openssl/sha.h>
#include "signing_progress.h"

bool ZSHA::SHA1(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[20];
	::SHA1(data, size, hash);
	strOutput.append((const char*)hash, 20);
	return true;
}

bool ZSHA::SHA256(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[32];
	::SHA256(data, size, hash);
	strOutput.append((const char*)hash, 32);
	return true;
}

bool ZSHA::SHA1(const string& strData, string& strOutput)
{
	return ZSHA::SHA1((uint8_t*)strData.data(), strData.size(), strOutput);
}

bool ZSHA::SHA256(const string& strData, string& strOutput)
{
	return ZSHA::SHA256((uint8_t*)strData.data(), strData.size(), strOutput);
}

bool ZSHA::SHA(const string& strData, string& strSHA1, string& strSHA256)
{
	ZSHA::SHA1(strData, strSHA1);
	ZSHA::SHA256(strData, strSHA256);
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHA1Text(const string& strData, string& strOutput)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);

	static const char hex_lower[] = "0123456789abcdef";
	strOutput.clear();
	strOutput.reserve(strSHASum.size() * 2);
	for (size_t i = 0; i < strSHASum.size(); i++) {
		uint8_t c = (uint8_t)strSHASum[i];
		strOutput += hex_lower[c >> 4];
		strOutput += hex_lower[c & 0x0F];
	}
	return (!strOutput.empty());
}

bool ZSHA::SHAFile(const char* szFile, string& strSHA1, string& strSHA256)
{
	strSHA1.clear();
	strSHA256.clear();
	size_t sSize = 0;
	uint8_t* pBase = (uint8_t*)ZFile::MapFile(szFile, 0, 0, &sSize, true);
	// pBase may be NULL, but it's ok, because the file may be empty
	if (ZSigningProgress::callback && pBase && sSize > 0) {
		SHA_CTX sha1;
		SHA256_CTX sha256;
		::SHA1_Init(&sha1);
		::SHA256_Init(&sha256);
		const size_t chunk = 4 * 1024 * 1024;
		for (size_t offset = 0; offset < sSize;) {
			const size_t length = std::min(chunk, sSize - offset);
			::SHA1_Update(&sha1, pBase + offset, length);
			::SHA256_Update(&sha256, pBase + offset, length);
			offset += length;
			ZSigningProgress::Report(double(offset) / sSize);
		}
		unsigned char hash1[SHA_DIGEST_LENGTH], hash256[SHA256_DIGEST_LENGTH];
		::SHA1_Final(hash1, &sha1);
		::SHA256_Final(hash256, &sha256);
		strSHA1.assign((const char*)hash1, sizeof(hash1));
		strSHA256.assign((const char*)hash256, sizeof(hash256));
	} else {
		ZSHA::SHA1(pBase, sSize, strSHA1);
		ZSHA::SHA256(pBase, sSize, strSHA256);
	}
	if (NULL != pBase && sSize > 0) {
		ZFile::UnmapFile(pBase, sSize);
	}
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHABase64(const string& strData, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHA(strData, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

bool ZSHA::SHABase64File(const char* szFile, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHAFile(szFile, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

void ZSHA::Print(const char* prefix, const uint8_t* hash, uint32_t size, const char* suffix)
{
	ZLog::PrintV("%s", prefix);
	for (uint32_t i = 0; i < size; i++) {
		ZLog::PrintV("%02x", hash[i]);
	}
	ZLog::PrintV("%s", suffix);
}

void ZSHA::Print(const char* prefix, const string& strSHASum, const char* suffix)
{
	Print(prefix, (const uint8_t*)strSHASum.data(), (uint32_t)strSHASum.size(), suffix);
}

void ZSHA::PrintData1(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData1(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}
