#pragma once
#include "common.h"
#include "json.h"
#include "openssl.h"
#include <vector>
#include <list>
#include <set>

class ZBundle
{
public:
	ZBundle();
	std::function<void(double)> progress;

public:
	bool SignFolder(ZSignAsset* pSignAsset,
					const string& strFolder,
					const string& strBundleId,
					const string& strBundleVersion,
					const string& strDisplayName,
					const vector<string>& arrDylibFiles,
					const vector<string>& arrRemoveDylibNames,
					bool bForce,
					bool bWeakInject,
					bool bEnableCache,
					bool bRemoveProvision);

	bool SignFolder(list<ZSignAsset>* pSignAssets,
					const string& strFolder,
					const string& strBundleId,
					const string& strBundleVersion,
					const string& strDisplayName,
					const vector<string>& arrDylibFiles,
					const vector<string>& arrRemoveDylibNames,
					bool bForce,
					bool bWeakInject,
					bool bEnableCache,
					bool bRemoveProvision = false);

private:
	bool SignNode(jvalue& jvNode);
	size_t CountSigningUnits(jvalue& node);
	void FinishSigningUnit();
	void ReportSigningProgress(double fraction);
	double m_lastSigningProgress = 0;
	size_t m_totalSigningUnits = 1;
	size_t m_completedSigningUnits = 0;
	void GetNodeChangedFiles(jvalue& jvNode, bool dontGenerateEmbeddedMobileProvision);
	void GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles);
	bool ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId);
	bool ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName);

private:
	bool FindAppFolder(const string& strFolder, string& strAppFolder);
	bool GetObjectsToSign(const string& strFolder, jvalue& jvInfo);
	bool GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName = false);

private:
	bool GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes);

private:
	bool			m_bForceSign;
	bool			m_bWeakInject;
	bool			m_bRemoveProvision;
	ZSignAsset*		m_pSignAsset;
	list<ZSignAsset>*	m_pSignAssets;
	vector<string>	m_arrInjectDylibs;
	set<string>		m_setRemoveDylibs;

private:
	void ApplyAppModifications();

public:
	bool		m_bEnableDocuments;
	string		m_strMinVersion;
	bool		m_bRemoveExtensions;
	bool		m_bRemoveWatchApp;
	bool		m_bRemoveUISupportedDevices;
	string			m_strAppFolder;
};
