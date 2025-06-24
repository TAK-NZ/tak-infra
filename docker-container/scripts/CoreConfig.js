import * as fs from 'node:fs';
import * as fsp from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { toPem } from 'jks-js';
import { diff } from 'json-diff-ts';
import { execSync } from 'node:child_process';
import * as xmljs from 'xml-js';
for (const env of [
    'PostgresUsername',
    'PostgresPassword',
    'PostgresURL',
    'TAK_VERSION',
    'LDAP_DN',
    'LDAP_SECURE_URL'
]) {
    if (!process.env[env]) {
        console.error(`${env} Environment Variable not set`);
        process.exit(1);
    }
}
// Get AWS Root CA as the LDAP Stack is behind an NLB with an AWS Cert
const Amazon_Root_Cert = await (await fetch('https://www.amazontrust.com/repository/AmazonRootCA1.pem')).text();
await fsp.writeFile('/tmp/AmazonRootCA1.pem', Amazon_Root_Cert);
execSync('yes | keytool -import -file /tmp/AmazonRootCA1.pem -alias AWS -deststoretype JKS -deststorepass INTENTIONALLY_NOT_SENSITIVE -keystore /tmp/AmazonRootCA1.jks', {
    stdio: 'inherit'
});
await fsp.copyFile('/tmp/AmazonRootCA1.jks', '/opt/tak/certs/files/aws-acm-root.jks');
const LetsEncrypt = {
    Domain: process.env.TAKSERVER_QuickConnect_LetsEncrypt_Domain || 'nodomainset'
};
const Certificate = {
    O: process.env.TAKSERVER_CACert_Org || 'TAK',
    OU: process.env.TAKSERVER_CACert_OrgUnit || 'TAK Unit'
};
const InputConfig = {
    Auth: process.env.TAKSERVER_CoreConfig_Network_Input_8089_Auth || 'x509'
};
const Connector = {
    EnableAdminUI8443: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8443_EnableAdminUI) || true,
    EnableNonAdminUI8443: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8443_EnableNonAdminUI) || true,
    EnableWebtak8443: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8443_EnableWebtak) || true,
    EnableAdminUI8446: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8446_EnableAdminUI) || true,
    EnableNonAdminUI8446: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8446_EnableNonAdminUI) || true,
    EnableWebtak8446: stringToBoolean(process.env.TAKSERVER_CoreConfig_Network_Connector_8446_EnableWebtak) || true
};
const LDAP_Auth = {
    X509groups: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_X509groups) || true,
    X509addAnonymous: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_X509addAnonymous) || false,
    X509useGroupCache: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_X509useGroupCache) || true,
    X509useGroupCacheDefaultActive: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_X509useGroupCacheDefaultActive) || true,
    X509checkRevocation: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_X509checkRevocation) || true,
    LDAP_Userstring: process.env.TAKSERVER_CoreConfig_Auth_LDAP_Userstring || 'cn={username},ou=users,',
    LDAP_Updateinterval: parseInt(process.env.TAKSERVER_CoreConfig_Auth_LDAP_Updateinterval) || 60,
    LDAP_Groupprefix: process.env.TAKSERVER_CoreConfig_Auth_LDAP_Groupprefix || '',
    LDAP_GroupNameExtractorRegex: process.env.TAKSERVER_CoreConfig_Auth_LDAP_GroupNameExtractorRegex || 'CN=(.*?)(?:,|$)',
    LDAP_NestedGroupLookup: stringToBoolean(process.env.TAKSERVER_CoreConfig_Auth_LDAP_NestedGroupLookup) || false,
    LDAP_Style: process.env.TAKSERVER_CoreConfig_Auth_LDAP_Style || 'DS',
    LDAP_ServiceAccountDN: process.env.TAKSERVER_CoreConfig_Auth_LDAP_ServiceAccountDN || 'cn=ldapservice,ou=users,',
    LDAP_UserObjectClass: process.env.TAKSERVER_CoreConfig_Auth_LDAP_UserObjectClass || 'user',
    LDAP_GroupObjectClass: process.env.TAKSERVER_CoreConfig_Auth_LDAP_GroupObjectClass || 'group',
    LDAP_DnAttributeName: process.env.TAKSERVER_CoreConfig_Auth_LDAP_DnAttributeName || 'dn',
    LDAP_NameAttr: process.env.TAKSERVER_CoreConfig_Auth_LDAP_NameAttr || 'cn',
    LDAP_UserBaseRDN: process.env.TAKSERVER_CoreConfig_Auth_LDAP_UserBaseRDN || 'ou=users,',
    LDAP_GroupBaseRDN: process.env.TAKSERVER_CoreConfig_Auth_LDAP_GroupBaseRDN || 'ou=groups,',
    LDAP_CallsignAttribute: process.env.TAKSERVER_CoreConfig_Auth_LDAP_CallsignAttribute || 'takCallsign',
    LDAP_ColorAttribute: process.env.TAKSERVER_CoreConfig_Auth_LDAP_ColorAttribute || 'takColor',
    LDAP_RoleAttribute: process.env.TAKSERVER_CoreConfig_Auth_LDAP_RoleAttribute || 'takRole'
};
const Federation = {
    EnableFederation: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_EnableFederation) || true,
    AllowFederatedDelete: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_AllowFederatedDelete) || false,
    AllowMissionFederation: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_AllowMissionFederation) || true,
    AllowDataFeedFederation: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_AllowDataFeedFederation) || true,
    EnableMissionFederationDisruptionTolerance: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_EnableMissionFederationDisruptionTolerance) || true,
    MissionFederationDisruptionToleranceRecencySeconds: parseInt(process.env.TAKSERVER_CoreConfig_Federation_MissionFederationDisruptionToleranceRecencySeconds) || 43200,
    EnableDataPackageAndMissionFileFilter: stringToBoolean(process.env.TAKSERVER_CoreConfig_Federation_EnableDataPackageAndMissionFileFilter) || false,
    Federation_WebBaseUrl: process.env.TAKSERVER_CoreConfig_Federation_WebBaseUrl || 'https://localhost:8443/Marti'
};
const OAuth = {
    OauthUseGroupCache: stringToBoolean(process.env.TAKSERVER_CoreConfig_OAuth_OauthUseGroupCache || 'false'),
    LoginWithEmail: stringToBoolean(process.env.TAKSERVER_CoreConfig_OAuth_LoginWithEmail || 'false'),
    UseTakServerLoginPage: stringToBoolean(process.env.TAKSERVER_CoreConfig_OAuth_UseTakServerLoginPage || 'false'),
    GroupsClaim: process.env.TAKSERVER_CoreConfig_OAuth_GroupsClaim,
    UsernameClaim: process.env.TAKSERVER_CoreConfig_OAuth_UsernameClaim,
    ScopeClaim: process.env.TAKSERVER_CoreConfig_OAuth_ScopeClaim,
    WebtakScope: process.env.TAKSERVER_CoreConfig_OAuth_WebtakScope,
    Groupprefix: process.env.TAKSERVER_CoreConfig_OAuth_Groupprefix,
    AllowUriQueryParameter: stringToBoolean(process.env.TAKSERVER_CoreConfig_OAuth_AllowUriQueryParameter || 'false'),
    OAuthServerName: process.env.TAKSERVER_CoreConfig_OAuthServer_Name,
    OAuthServerIssuer: process.env.TAKSERVER_CoreConfig_OAuthServer_Issuer,
    OAuthServerClientId: process.env.TAKSERVER_CoreConfig_OAuthServer_ClientId,
    OAuthServerSecret: process.env.TAKSERVER_CoreConfig_OAuthServer_Secret,
    OAuthServerRedirectUri: process.env.TAKSERVER_CoreConfig_OAuthServer_RedirectUri,
    OAuthServerScope: process.env.TAKSERVER_CoreConfig_OAuthServer_Scope,
    OAuthServerAuthEndpoint: process.env.TAKSERVER_CoreConfig_OAuthServer_AuthEndpoint,
    OAuthServerTokenEndpoint: process.env.TAKSERVER_CoreConfig_OAuthServer_TokenEndpoint,
    OAuthServerAccessTokenName: process.env.TAKSERVER_CoreConfig_OAuthServer_AccessTokenName,
    OAuthServerRefreshTokenName: process.env.TAKSERVER_CoreConfig_OAuthServer_RefreshTokenName,
    OAuthServerTrustAllCerts: stringToBoolean(process.env.TAKSERVER_CoreConfig_OAuthServer_TrustAllCerts || 'false')
};
const RemoteCoreConfig = null;
let CoreConfig = null;
/* TODO Remote Core Config
    try {
        // Ensure seperate objects are created as CoreConfig will be mutated if there are
        // Stack Config values that chage
        RemoteCoreConfig = TypeValidator.type(
            CoreConfigType,
            xmljs.xml2js(existingCoreConfig.SecretString, { compact: true }),
            {
                clean: false,
                verbose: true,
                convert: true,
                default: true
            }
        );

        CoreConfig = structuredClone(RemoteCoreConfig);
    } catch (err) {
        console.error(err);
    }
*/
if (!CoreConfig) {
    CoreConfig = {
        Configuration: {
            _attributes: {
                xmlns: 'http://bbn.com/marti/xml/config'
            },
            network: {
                _attributes: {
                    multicastTTL: 5,
                    serverId: randomUUID(),
                    version: process.env.TAK_VERSION,
                    cloudwatchEnable: true,
                    cloudwatchName: process.env.StackName
                },
                input: {
                    _attributes: {
                        auth: InputConfig.Auth,
                        _name: 'stdssl',
                        protocol: 'tls',
                        port: 8089,
                        coreVersion: 2
                    }
                },
                connector: [{
                        _attributes: {
                            port: 8443,
                            _name: 'https',
                            keystore: 'JKS',
                            keystoreFile: `/opt/tak/certs/files/${LetsEncrypt.Domain}/letsencrypt.jks`,
                            keystorePass: 'atakatak',
                            enableNonAdminUI: Connector.EnableNonAdminUI8443,
                            enableAdminUI: Connector.EnableAdminUI8443,
                            enableWebtak: Connector.EnableWebtak8443
                        }
                    }, {
                        _attributes: {
                            port: 8446,
                            clientAuth: false,
                            _name: 'cert_https',
                            keystore: 'JKS',
                            keystoreFile: `/opt/tak/certs/files/${LetsEncrypt.Domain}/letsencrypt.jks`,
                            keystorePass: 'atakatak',
                            enableNonAdminUI: Connector.EnableNonAdminUI8446,
                            enableAdminUI: Connector.EnableAdminUI8446,
                            enableWebtak: Connector.EnableWebtak8446
                        }
                    }],
                announce: {
                    _attributes: {}
                }
            },
            auth: {
                _attributes: {
                    default: 'ldap',
                    x509groups: LDAP_Auth.X509groups,
                    x509addAnonymous: LDAP_Auth.X509addAnonymous,
                    x509useGroupCache: LDAP_Auth.X509useGroupCache,
                    x509useGroupCacheDefaultActive: LDAP_Auth.X509useGroupCacheDefaultActive,
                    x509checkRevocation: LDAP_Auth.X509checkRevocation
                },
                ldap: {
                    _attributes: {
                        url: process.env.LDAP_SECURE_URL,
                        userstring: LDAP_Auth.LDAP_Userstring + process.env.LDAP_DN,
                        updateinterval: LDAP_Auth.LDAP_Updateinterval,
                        groupprefix: LDAP_Auth.LDAP_Groupprefix,
                        groupNameExtractorRegex: LDAP_Auth.LDAP_GroupNameExtractorRegex,
                        style: LDAP_Auth.LDAP_Style,
                        serviceAccountDN: LDAP_Auth.LDAP_ServiceAccountDN + process.env.LDAP_DN,
                        serviceAccountCredential: process.env.LDAP_Password,
                        userObjectClass: LDAP_Auth.LDAP_UserObjectClass,
                        groupObjectClass: LDAP_Auth.LDAP_GroupObjectClass,
                        groupBaseRDN: LDAP_Auth.LDAP_GroupBaseRDN + process.env.LDAP_DN,
                        userBaseRDN: LDAP_Auth.LDAP_UserBaseRDN + process.env.LDAP_DN,
                        dnAttributeName: LDAP_Auth.LDAP_DnAttributeName,
                        nameAttr: LDAP_Auth.LDAP_NameAttr,
                        nestedGroupLookup: LDAP_Auth.LDAP_NestedGroupLookup,
                        callsignAttribute: LDAP_Auth.LDAP_CallsignAttribute,
                        colorAttribute: LDAP_Auth.LDAP_ColorAttribute,
                        roleAttribute: LDAP_Auth.LDAP_RoleAttribute,
                        ldapsTruststore: 'JKS',
                        ldapsTruststoreFile: '/opt/tak/certs/files/aws-acm-root.jks',
                        ldapsTruststorePass: 'INTENTIONALLY_NOT_SENSITIVE',
                        enableConnectionPool: false
                    }
                },
                ...(OAuth.OAuthServerName && OAuth.OAuthServerIssuer && OAuth.OAuthServerClientId && OAuth.OAuthServerSecret && OAuth.OAuthServerRedirectUri && OAuth.OAuthServerAuthEndpoint && OAuth.OAuthServerTokenEndpoint) && ({
                    oauth: {
                        _attributes: {
                            ...(OAuth.OauthUseGroupCache && { oauthUseGroupCache: OAuth.OauthUseGroupCache }),
                            ...(OAuth.LoginWithEmail && { loginWithEmail: OAuth.LoginWithEmail }),
                            ...(OAuth.UseTakServerLoginPage && { useTakServerLoginPage: OAuth.UseTakServerLoginPage }),
                            ...(OAuth.GroupsClaim && { groupsClaim: OAuth.GroupsClaim }),
                            ...(OAuth.UsernameClaim && { usernameClaim: OAuth.UsernameClaim }),
                            ...(OAuth.ScopeClaim && { scopeClaim: OAuth.ScopeClaim }),
                            ...(OAuth.WebtakScope && { webtakScope: OAuth.WebtakScope }),
                            ...(OAuth.Groupprefix && { groupprefix: OAuth.Groupprefix }),
                            ...(OAuth.AllowUriQueryParameter && { allowUriQueryParameter: OAuth.AllowUriQueryParameter })
                        },
                        authServer: {
                            _attributes: {
                                name: OAuth.OAuthServerName,
                                issuer: OAuth.OAuthServerIssuer,
                                clientId: OAuth.OAuthServerClientId,
                                secret: OAuth.OAuthServerSecret,
                                redirectUri: OAuth.OAuthServerRedirectUri,
                                authEndpoint: OAuth.OAuthServerAuthEndpoint,
                                ...(OAuth.OAuthServerScope && { scope: OAuth.OAuthServerScope }),
                                tokenEndpoint: OAuth.OAuthServerTokenEndpoint,
                                ...(OAuth.OAuthServerAccessTokenName && { accessTokenName: OAuth.OAuthServerAccessTokenName }),
                                ...(OAuth.OAuthServerRefreshTokenName && { refreshTokenName: OAuth.OAuthServerRefreshTokenName }),
                                ...(OAuth.OAuthServerTrustAllCerts && { trustAllCerts: OAuth.OAuthServerTrustAllCerts })
                            }
                        }
                    }
                })
            },
            submission: {
                _attributes: {
                    ignoreStaleMessages: false,
                    validateXml: false
                }
            },
            subscription: {
                _attributes: {
                    reloadPersistent: false
                }
            },
            repository: {
                _attributes: {
                    enable: true,
                    numDbConnections: 16,
                    primaryKeyBatchSize: 500,
                    insertionBatchSize: 500
                },
                connection: {
                    _attributes: {
                        url: `jdbc:${process.env.PostgresURL}`,
                        username: process.env.PostgresUsername,
                        password: process.env.PostgresPassword
                    }
                }
            },
            repeater: {
                _attributes: {
                    enable: true,
                    periodMillis: 3000,
                    staleDelayMillis: 15000
                },
                repeatableType: [{
                        _attributes: {
                            'initiate-test': "/event/detail/emergency[@type='911 Alert']",
                            'cancel-test': "/event/detail/emergency[@cancel='true']",
                            _name: '911'
                        }
                    }, {
                        _attributes: {
                            'initiate-test': "/event/detail/emergency[@type='Ring The Bell']",
                            'cancel-test': "/event/detail/emergency[@cancel='true']",
                            _name: 'RingTheBell'
                        }
                    }, {
                        _attributes: {
                            'initiate-test': "/event/detail/emergency[@type='Geo-fence Breached']",
                            'cancel-test': "/event/detail/emergency[@cancel='true']",
                            _name: 'GeoFenceBreach'
                        }
                    }, {
                        _attributes: {
                            'initiate-test': "/event/detail/emergency[@type='Troops In Contact']",
                            'cancel-test': "/event/detail/emergency[@cancel='true']",
                            _name: 'TroopsInContact'
                        }
                    }]
            },
            filter: {
                _attributes: {}
            },
            buffer: {
                _attributes: {},
                queue: {
                    _attributes: {},
                    priority: {
                        _attributes: {}
                    }
                },
                latestSA: {
                    _attributes: {
                        enable: true
                    }
                }
            },
            dissemination: {
                _attributes: {
                    smartRetry: false
                }
            },
            certificateSigning: {
                _attributes: {
                    CA: 'TAKServer'
                },
                certificateConfig: {
                    nameEntries: {
                        nameEntry: [{
                                _attributes: {
                                    name: 'O',
                                    value: Certificate.O
                                }
                            }, {
                                _attributes: {
                                    name: 'OU',
                                    value: Certificate.OU
                                }
                            }]
                    }
                },
                TAKServerCAConfig: {
                    _attributes: {
                        keystore: 'JKS',
                        keystoreFile: '/opt/tak/certs/files/intermediate-ca-signing.jks',
                        keystorePass: 'atakatak',
                        validityDays: '365',
                        signatureAlg: 'SHA256WithRSA',
                        CAkey: '/opt/tak/certs/files/intermediate-ca-signing',
                        CAcertificate: '/opt/tak/certs/files/intermediate-ca-signing'
                    }
                }
            },
            security: {
                tls: {
                    _attributes: {
                        keystore: 'JKS',
                        keystoreFile: '/opt/tak/certs/files/takserver.jks',
                        keystorePass: 'atakatak',
                        truststore: 'JKS',
                        truststoreFile: '/opt/tak/certs/files/truststore-intermediate-ca.jks',
                        truststorePass: 'atakatak',
                        context: 'TLSv1.2',
                        keymanager: 'SunX509'
                    }
                },
                missionTls: {
                    _attributes: {
                        keystore: 'JKS',
                        keystoreFile: '/opt/tak/certs/files/truststore-root.jks',
                        keystorePass: 'atakatak'
                    }
                }
            },
            federation: {
                _attributes: {
                    allowFederatedDelete: Federation.AllowFederatedDelete,
                    allowMissionFederation: Federation.AllowMissionFederation,
                    allowDataFeedFederation: Federation.AllowDataFeedFederation,
                    enableMissionFederationDisruptionTolerance: Federation.EnableMissionFederationDisruptionTolerance,
                    missionFederationDisruptionToleranceRecencySeconds: Federation.MissionFederationDisruptionToleranceRecencySeconds,
                    enableFederation: Federation.EnableFederation,
                    enableDataPackageAndMissionFileFilter: Federation.EnableDataPackageAndMissionFileFilter
                },
                'federation-server': {
                    _attributes: {
                        port: 9000,
                        coreVersion: 2,
                        v1enabled: false,
                        v2port: 9001,
                        v2enabled: true,
                        webBaseUrl: Federation.Federation_WebBaseUrl,
                    },
                    tls: {
                        _attributes: {
                            keystore: 'JKS',
                            keystoreFile: '/opt/tak/certs/files/takserver.jks',
                            keystorePass: 'atakatak',
                            truststore: 'JKS',
                            truststoreFile: '/opt/tak/certs/files/fed-truststore.jks',
                            truststorePass: 'atakatak',
                            context: 'TLSv1.2',
                            keymanager: 'SunX509'
                        }
                    },
                    'federation-port': {
                        _attributes: {
                            port: 9000,
                            tlsVersion: 'TLSv1.2'
                        }
                    },
                    v1Tls: [{
                            _attributes: {
                                tlsVersion: 'TLSv1.2'
                            }
                        }, {
                            _attributes: {
                                tlsVersion: 'TLSv1.3'
                            }
                        }]
                },
                fileFilter: {
                    fileExtension: ['pref']
                }
            },
            plugins: {},
            cluster: {},
            vbm: {}
        }
    };
}
if (CoreConfig.Configuration.network.connector) {
    if (!Array.isArray(CoreConfig.Configuration.network.connector)) {
        CoreConfig.Configuration.network.connector = [CoreConfig.Configuration.network.connector];
    }
    for (const connector of CoreConfig.Configuration.network.connector) {
        if (connector._attributes.keystoreFile && connector._attributes.keystorePass) {
            validateKeystore(connector._attributes.keystoreFile, connector._attributes.keystorePass);
        }
    }
}
else {
    console.warn('No Network Connectors Found');
}
if (CoreConfig.Configuration.certificateSigning.TAKServerCAConfig) {
    validateKeystore(CoreConfig.Configuration.certificateSigning.TAKServerCAConfig._attributes.keystoreFile, CoreConfig.Configuration.certificateSigning.TAKServerCAConfig._attributes.keystorePass);
}
if (CoreConfig.Configuration.auth.ldap) {
    validateKeystore(CoreConfig.Configuration.auth.ldap._attributes.ldapsTruststoreFile, CoreConfig.Configuration.auth.ldap._attributes.ldapsTruststorePass);
}
if (CoreConfig.Configuration.security) {
    if (CoreConfig.Configuration.security.tls) {
        validateKeystore(CoreConfig.Configuration.security.tls._attributes.keystoreFile, CoreConfig.Configuration.security.tls._attributes.keystorePass);
    }
    if (CoreConfig.Configuration.security.missionTls) {
        validateKeystore(CoreConfig.Configuration.security.missionTls._attributes.keystoreFile, CoreConfig.Configuration.security.missionTls._attributes.keystorePass);
    }
}
const xml = xmljs.js2xml(CoreConfig, {
    spaces: 4,
    compact: true
});
fs.writeFileSync('/opt/tak/CoreConfig.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n${xml}`);
try {
    console.log('ok - TAK Server - Checking for Diff in CoreConfig.xml');
    const diffs = diff(RemoteCoreConfig, CoreConfig);
    if (diffs.length > 0) {
        console.log('ok - TAK Server - CoreConfig.xml change detected');
    }
    else {
        console.log('ok - TAK Server - No CoreConfig.xml change detected');
    }
}
catch (err) {
    console.error(err);
}
function validateKeystore(file, pass) {
    fs.accessSync(file);
    const jksBuffer = fs.readFileSync(file);
    toPem(jksBuffer, pass);
}
function stringToBoolean(str) {
    return str.toLowerCase() === 'true';
}
//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJmaWxlIjoiQ29yZUNvbmZpZy5qcyIsInNvdXJjZVJvb3QiOiIiLCJzb3VyY2VzIjpbIkNvcmVDb25maWcudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQUEsT0FBTyxLQUFLLEVBQUUsTUFBTSxTQUFTLENBQUM7QUFDOUIsT0FBTyxLQUFLLEdBQUcsTUFBTSxrQkFBa0IsQ0FBQztBQUd4QyxPQUFPLEVBQUUsVUFBVSxFQUFFLE1BQU0sYUFBYSxDQUFDO0FBQ3pDLE9BQU8sRUFBRSxLQUFLLEVBQUUsTUFBTSxRQUFRLENBQUM7QUFDL0IsT0FBTyxFQUFFLElBQUksRUFBRSxNQUFNLGNBQWMsQ0FBQztBQUNwQyxPQUFPLEVBQUUsUUFBUSxFQUFFLE1BQU0sb0JBQW9CLENBQUM7QUFDOUMsT0FBTyxLQUFLLEtBQUssTUFBTSxRQUFRLENBQUM7QUFFaEMsS0FBSyxNQUFNLEdBQUcsSUFBSTtJQUNkLGtCQUFrQjtJQUNsQixrQkFBa0I7SUFDbEIsYUFBYTtJQUNiLGFBQWE7SUFDYixTQUFTO0lBQ1QsaUJBQWlCO0NBQ3BCLEVBQUUsQ0FBQztJQUNBLElBQUksQ0FBQyxPQUFPLENBQUMsR0FBRyxDQUFDLEdBQUcsQ0FBQyxFQUFFLENBQUM7UUFDcEIsT0FBTyxDQUFDLEtBQUssQ0FBQyxHQUFHLEdBQUcsK0JBQStCLENBQUMsQ0FBQztRQUNyRCxPQUFPLENBQUMsSUFBSSxDQUFDLENBQUMsQ0FBQyxDQUFDO0lBQ3BCLENBQUM7QUFDTCxDQUFDO0FBRUQsc0VBQXNFO0FBQ3RFLE1BQU0sZ0JBQWdCLEdBQUcsTUFBTSxDQUFDLE1BQU0sS0FBSyxDQUFDLDBEQUEwRCxDQUFDLENBQUMsQ0FBQyxJQUFJLEVBQUUsQ0FBQztBQUNoSCxNQUFNLEdBQUcsQ0FBQyxTQUFTLENBQUMsd0JBQXdCLEVBQUUsZ0JBQWdCLENBQUMsQ0FBQztBQUVoRSxRQUFRLENBQUMsOEpBQThKLEVBQUU7SUFDckssS0FBSyxFQUFFLFNBQVM7Q0FDbkIsQ0FBQyxDQUFDO0FBRUgsTUFBTSxHQUFHLENBQUMs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LENBQUMsTUFBTSxHQUFHLENBQUMsRUFBRSxDQUFDO1FBQ25CLE9BQU8sQ0FBQyxHQUFHLENBQUMsa0RBQWtELENBQUMsQ0FBQztJQUNwRSxDQUFDO1NBQU0sQ0FBQztRQUNKLE9BQU8sQ0FBQyxHQUFHLENBQUMscURBQXFELENBQUMsQ0FBQztJQUN2RSxDQUFDO0FBQ0wsQ0FBQztBQUFDLE9BQU8sR0FBRyxFQUFFLENBQUM7SUFDWCxPQUFPLENBQUMsS0FBSyxDQUFDLEdBQUcsQ0FBQyxDQUFDO0FBQ3ZCLENBQUM7QUFFRCxTQUFTLGdCQUFnQixDQUFDLElBQUksRUFBRSxJQUFJO0lBQ2hDLEVBQUUsQ0FBQyxVQUFVLENBQUMsSUFBSSxDQUFDLENBQUM7SUFDcEIsTUFBTSxTQUFTLEdBQUcsRUFBRSxDQUFDLFlBQVksQ0FBQyxJQUFJLENBQUMsQ0FBQztJQUN4QyxLQUFLLENBQUMsU0FBUyxFQUFFLElBQUksQ0FBQyxDQUFDO0FBQzNCLENBQUM7QUFFRCxTQUFTLGVBQWUsQ0FBQyxHQUFXO0lBQ2hDLE9BQU8sR0FBRyxDQUFDLFdBQVcsRUFBRSxLQUFLLE1BQU0sQ0FBQztBQUN4QyxDQUFDIiwic291cmNlc0NvbnRlbnQiOlsiaW1wb3J0ICogYXMgZnMgZnJvbSAnbm9kZTpmcyc7XG5pbXBvcnQgKiBhcyBmc3AgZnJvbSAnbm9kZTpmcy9wcm9taXNlcyc7XG5pbXBvcnQgeyBTdGF0aWMgfSBmcm9tICdAc2luY2xhaXIvdHlwZWJveCc7XG5pbXBvcnQgQ29yZUNvbmZpZ1R5cGUgZnJvbSAnL29wdC90YWsvc2NyaXB0cy9zcmMvQ29yZUNvbmZpZ1R5cGUuanMnO1xuaW1wb3J0IHsgcmFuZG9tVVVJRCB9IGZyb20gJ25vZGU6Y3J5cHRvJztcbmltcG9ydCB7IHRvUGVtIH0gZnJvbSAnamtzLWpzJztcbmltcG9ydCB7IGRpZmYgfSBmcm9tICdqc29uLWRpZmYtdHMnO1xuaW1wb3J0IHsgZXhlY1N5bmMgfSBmcm9tICdub2RlOmNoaWxkX3Byb2Nlc3MnO1xuaW1wb3J0ICogYXMgeG1sanMgZnJvbSAneG1sLWpzJztcblxuZm9yIChjb25zdCBlbnYgb2YgW1xuICAgICdQb3N0Z3Jlc1VzZXJuYW1lJyxcbiAgICAnUG9zdGdyZXNQYXNzd29yZCcsXG4gICAgJ1Bvc3RncmVzVVJMJyxcbiAgICAnVEFLX1ZFUlNJT04nLFxuICAgICdMREFQX0ROJyxcbiAgICAnTERBUF9TRUNVUkVfVVJMJ1xuXSkge1xuICAgIGlmICghcHJvY2Vzcy5lbnZbZW52XSkge1xuICAgICAgICBjb25zb2xlLmVycm9yKGAke2Vudn0gRW52aXJvbm1lbnQgVmFyaWFibGUgbm90IHNldGApO1xuICAgICAgICBwcm9jZXNzLmV4aXQoMSk7XG4gICAgfVxufVxuXG4vLyBHZXQgQVdTIFJvb3QgQ0EgYXMgdGhlIExEQVAgU3RhY2sgaXMgYmVoaW5kIGFuIE5MQiB3aXRoIGFuIEFXUyBDZXJ0XG5jb25zdCBBbWF6b25fUm9vdF9DZXJ0ID0gYXdhaXQgKGF3YWl0IGZldGNoKCdodHRwczovL3d3dy5hbWF6b250cnVzdC5jb20vcmVwb3NpdG9yeS9BbWF6b25Sb290Q0ExLnBlbScpKS50ZXh0KCk7XG5hd2FpdCBmc3Aud3JpdGVGaWxlKCcvdG1wL0FtYXpvblJvb3RDQTEucGVtJywgQW1hem9uX1Jvb3RfQ2VydCk7XG5cbmV4ZWNTeW5jKCd5ZXMgfCBrZXl0b29sIC1pbXBvcnQgLWZpbGUgL3RtcC9BbWF6b25Sb290Q0ExLnBlbSAtYWxpYXMgQVdTIC1kZXN0c3RvcmV0eXBlIEpLUyAtZGVzdHN0b3JlcGFzcyBJTlRFTlRJT05BTExZX05PVF9TRU5TSVRJVkUgLWtleXN0b3JlIC90bXAvQW1hem9uUm9vdENBMS5qa3MnLCB7XG4gICAgc3RkaW86ICdpbmhlcml0J1xufSk7XG5cbmF3YWl0IGZzcC5jb3B5RmlsZSgnL3RtcC9BbWF6b25Sb290Q0ExLmprcycsICcvb3B0L3Rhay9jZXJ0cy9maWxlcy9hd3MtYWNtLXJvb3QuamtzJyk7XG5cbmNvbnN0IExldHNFbmNyeXB0ID0ge1xuICAgIERvbWFpbjogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX1F1aWNrQ29ubmVjdF9MZXRzRW5jcnlwdF9Eb21haW4gfHwgJ25vZG9tYWluc2V0J1xufVxuXG5jb25zdCBDZXJ0aWZpY2F0ZSA9IHtcbiAgICBPOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ0FDZXJ0X09yZyB8fCAnVEFLJyxcbiAgICBPVTogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NBQ2VydF9PcmdVbml0IHx8ICdUQUsgVW5pdCdcbn07XG5cbmNvbnN0IElucHV0Q29uZmlnID0ge1xuICAgIEF1dGg6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX05ldHdvcmtfSW5wdXRfODA4OV9BdXRoIHx8ICd4NTA5J1xufTtcblxuY29uc3QgQ29ubmVjdG9yID0ge1xuICAgIEVuYWJsZUFkbWluVUk4NDQzOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfTmV0d29ya19Db25uZWN0b3JfODQ0M19FbmFibGVBZG1pblVJKSB8fCB0cnVlLFxuICAgIEVuYWJsZU5vbkFkbWluVUk4NDQzOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfTmV0d29ya19Db25uZWN0b3JfODQ0M19FbmFibGVOb25BZG1pblVJKSB8fCB0cnVlLFxuICAgIEVuYWJsZVdlYnRhazg0NDM6IHN0cmluZ1RvQm9vbGVhbihwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19OZXR3b3JrX0Nvbm5lY3Rvcl84NDQzX0VuYWJsZVdlYnRhaykgfHwgdHJ1ZSxcbiAgICBFbmFibGVBZG1pblVJODQ0Njogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX05ldHdvcmtfQ29ubmVjdG9yXzg0NDZfRW5hYmxlQWRtaW5VSSkgfHwgdHJ1ZSxcbiAgICBFbmFibGVOb25BZG1pblVJODQ0Njogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX05ldHdvcmtfQ29ubmVjdG9yXzg0NDZfRW5hYmxlTm9uQWRtaW5VSSkgfHwgdHJ1ZSxcbiAgICBFbmFibGVXZWJ0YWs4NDQ2OiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfTmV0d29ya19Db25uZWN0b3JfODQ0Nl9FbmFibGVXZWJ0YWspIHx8IHRydWVcbn07XG5cbmNvbnN0IExEQVBfQXV0aCA9IHtcbiAgICBYNTA5Z3JvdXBzOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9YNTA5Z3JvdXBzKSB8fCB0cnVlLFxuICAgIFg1MDlhZGRBbm9ueW1vdXM6IHN0cmluZ1RvQm9vbGVhbihwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX1g1MDlhZGRBbm9ueW1vdXMpIHx8IGZhbHNlLFxuICAgIFg1MDl1c2VHcm91cENhY2hlOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9YNTA5dXNlR3JvdXBDYWNoZSkgfHwgdHJ1ZSxcbiAgICBYNTA5dXNlR3JvdXBDYWNoZURlZmF1bHRBY3RpdmU6IHN0cmluZ1RvQm9vbGVhbihwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX1g1MDl1c2VHcm91cENhY2hlRGVmYXVsdEFjdGl2ZSkgfHwgdHJ1ZSxcbiAgICBYNTA5Y2hlY2tSZXZvY2F0aW9uOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9YNTA5Y2hlY2tSZXZvY2F0aW9uKSB8fCB0cnVlLFxuICAgIExEQVBfVXNlcnN0cmluZzogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9MREFQX1VzZXJzdHJpbmcgfHwgJ2NuPXt1c2VybmFtZX0sb3U9dXNlcnMsJyxcbiAgICBMREFQX1VwZGF0ZWludGVydmFsOiBwYXJzZUludChwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfVXBkYXRlaW50ZXJ2YWwpIHx8IDYwLFxuICAgIExEQVBfR3JvdXBwcmVmaXg6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0F1dGhfTERBUF9Hcm91cHByZWZpeCB8fCAnJyxcbiAgICBMREFQX0dyb3VwTmFtZUV4dHJhY3RvclJlZ2V4OiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfR3JvdXBOYW1lRXh0cmFjdG9yUmVnZXggfHwgJ0NOPSguKj8pKD86LHwkKScsXG4gICAgTERBUF9OZXN0ZWRHcm91cExvb2t1cDogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0F1dGhfTERBUF9OZXN0ZWRHcm91cExvb2t1cCkgfHwgZmFsc2UsXG4gICAgTERBUF9TdHlsZTogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9MREFQX1N0eWxlIHx8ICdEUycsXG4gICAgTERBUF9TZXJ2aWNlQWNjb3VudEROOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfU2VydmljZUFjY291bnRETiB8fCAnY249bGRhcHNlcnZpY2Usb3U9dXNlcnMsJyxcbiAgICBMREFQX1VzZXJPYmplY3RDbGFzczogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9MREFQX1VzZXJPYmplY3RDbGFzcyB8fCAndXNlcicsXG4gICAgTERBUF9Hcm91cE9iamVjdENsYXNzOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfR3JvdXBPYmplY3RDbGFzcyB8fCAnZ3JvdXAnLFxuICAgIExEQVBfRG5BdHRyaWJ1dGVOYW1lOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfRG5BdHRyaWJ1dGVOYW1lIHx8ICdkbicsXG4gICAgTERBUF9OYW1lQXR0cjogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9MREFQX05hbWVBdHRyIHx8ICdjbicsXG4gICAgTERBUF9Vc2VyQmFzZVJETjogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfQXV0aF9MREFQX1VzZXJCYXNlUkROIHx8ICdvdT11c2VycywnLFxuICAgIExEQVBfR3JvdXBCYXNlUkROOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfR3JvdXBCYXNlUkROIHx8ICdvdT1ncm91cHMsJyxcbiAgICBMREFQX0NhbGxzaWduQXR0cmlidXRlOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfQ2FsbHNpZ25BdHRyaWJ1dGUgfHwgJ3Rha0NhbGxzaWduJyxcbiAgICBMREFQX0NvbG9yQXR0cmlidXRlOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19BdXRoX0xEQVBfQ29sb3JBdHRyaWJ1dGUgfHwgJ3Rha0NvbG9yJyxcbiAgICBMREFQX1JvbGVBdHRyaWJ1dGU6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0F1dGhfTERBUF9Sb2xlQXR0cmlidXRlIHx8ICd0YWtSb2xlJ1xuICAgIFxufTtcblxuY29uc3QgRmVkZXJhdGlvbiA9IHtcbiAgICBFbmFibGVGZWRlcmF0aW9uOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfRmVkZXJhdGlvbl9FbmFibGVGZWRlcmF0aW9uKSB8fCB0cnVlLFxuICAgIEFsbG93RmVkZXJhdGVkRGVsZXRlOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfRmVkZXJhdGlvbl9BbGxvd0ZlZGVyYXRlZERlbGV0ZSkgfHwgZmFsc2UsXG4gICAgQWxsb3dNaXNzaW9uRmVkZXJhdGlvbjogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0ZlZGVyYXRpb25fQWxsb3dNaXNzaW9uRmVkZXJhdGlvbikgfHwgdHJ1ZSxcbiAgICBBbGxvd0RhdGFGZWVkRmVkZXJhdGlvbjogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0ZlZGVyYXRpb25fQWxsb3dEYXRhRmVlZEZlZGVyYXRpb24pIHx8IHRydWUsXG4gICAgRW5hYmxlTWlzc2lvbkZlZGVyYXRpb25EaXNydXB0aW9uVG9sZXJhbmNlOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfRmVkZXJhdGlvbl9FbmFibGVNaXNzaW9uRmVkZXJhdGlvbkRpc3J1cHRpb25Ub2xlcmFuY2UpIHx8IHRydWUsXG4gICAgTWlzc2lvbkZlZGVyYXRpb25EaXNydXB0aW9uVG9sZXJhbmNlUmVjZW5jeVNlY29uZHM6IHBhcnNlSW50KHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX0ZlZGVyYXRpb25fTWlzc2lvbkZlZGVyYXRpb25EaXNydXB0aW9uVG9sZXJhbmNlUmVjZW5jeVNlY29uZHMpIHx8IDQzMjAwLFxuICAgIEVuYWJsZURhdGFQYWNrYWdlQW5kTWlzc2lvbkZpbGVGaWx0ZXI6IHN0cmluZ1RvQm9vbGVhbihwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19GZWRlcmF0aW9uX0VuYWJsZURhdGFQYWNrYWdlQW5kTWlzc2lvbkZpbGVGaWx0ZXIpIHx8IGZhbHNlLFxuICAgIEZlZGVyYXRpb25fV2ViQmFzZVVybDogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfRmVkZXJhdGlvbl9XZWJCYXNlVXJsIHx8ICdodHRwczovL2xvY2FsaG9zdDo4NDQzL01hcnRpJ1xufTtcblxuY29uc3QgT0F1dGggPSB7XG4gICAgT2F1dGhVc2VHcm91cENhY2hlOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfT0F1dGhfT2F1dGhVc2VHcm91cENhY2hlIHx8ICdmYWxzZScpLFxuICAgIExvZ2luV2l0aEVtYWlsOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfT0F1dGhfTG9naW5XaXRoRW1haWwgfHwgJ2ZhbHNlJyksXG4gICAgVXNlVGFrU2VydmVyTG9naW5QYWdlOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfT0F1dGhfVXNlVGFrU2VydmVyTG9naW5QYWdlIHx8ICdmYWxzZScpLFxuICAgIEdyb3Vwc0NsYWltOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aF9Hcm91cHNDbGFpbSxcbiAgICBVc2VybmFtZUNsYWltOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aF9Vc2VybmFtZUNsYWltLFxuICAgIFNjb3BlQ2xhaW06IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoX1Njb3BlQ2xhaW0sXG4gICAgV2VidGFrU2NvcGU6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoX1dlYnRha1Njb3BlLFxuICAgIEdyb3VwcHJlZml4OiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aF9Hcm91cHByZWZpeCxcbiAgICBBbGxvd1VyaVF1ZXJ5UGFyYW1ldGVyOiBzdHJpbmdUb0Jvb2xlYW4ocHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfT0F1dGhfQWxsb3dVcmlRdWVyeVBhcmFtZXRlciB8fCAnZmFsc2UnKSxcbiAgICBPQXV0aFNlcnZlck5hbWU6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoU2VydmVyX05hbWUsXG4gICAgT0F1dGhTZXJ2ZXJJc3N1ZXI6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoU2VydmVyX0lzc3VlcixcbiAgICBPQXV0aFNlcnZlckNsaWVudElkOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aFNlcnZlcl9DbGllbnRJZCxcbiAgICBPQXV0aFNlcnZlclNlY3JldDogcHJvY2Vzcy5lbnYuVEFLU0VSVkVSX0NvcmVDb25maWdfT0F1dGhTZXJ2ZXJfU2VjcmV0LFxuICAgIE9BdXRoU2VydmVyUmVkaXJlY3RVcmk6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoU2VydmVyX1JlZGlyZWN0VXJpLFxuICAgIE9BdXRoU2VydmVyU2NvcGU6IHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoU2VydmVyX1Njb3BlLFxuICAgIE9BdXRoU2VydmVyQXV0aEVuZHBvaW50OiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aFNlcnZlcl9BdXRoRW5kcG9pbnQsXG4gICAgT0F1dGhTZXJ2ZXJUb2tlbkVuZHBvaW50OiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aFNlcnZlcl9Ub2tlbkVuZHBvaW50LFxuICAgIE9BdXRoU2VydmVyQWNjZXNzVG9rZW5OYW1lOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aFNlcnZlcl9BY2Nlc3NUb2tlbk5hbWUsXG4gICAgT0F1dGhTZXJ2ZXJSZWZyZXNoVG9rZW5OYW1lOiBwcm9jZXNzLmVudi5UQUtTRVJWRVJfQ29yZUNvbmZpZ19PQXV0aFNlcnZlcl9SZWZyZXNoVG9rZW5OYW1lLFxuICAgIE9BdXRoU2VydmVyVHJ1c3RBbGxDZXJ0czogc3RyaW5nVG9Cb29sZWFuKHByb2Nlc3MuZW52LlRBS1NFUlZFUl9Db3JlQ29uZmlnX09BdXRoU2VydmVyX1RydXN0QWxsQ2VydHMgfHwgJ2ZhbHNlJylcbn07XG5cbmNvbnN0IFJlbW90ZUNvcmVDb25maWc6IFN0YXRpYzx0eXBlb2YgQ29yZUNvbmZpZ1R5cGU+IHwgbnVsbCA9IG51bGw7XG5sZXQgQ29yZUNvbmZpZzogU3RhdGljPHR5cGVvZiBDb3JlQ29uZmlnVHlwZT4gfCBudWxsID0gbnVsbDtcblxuLyogVE9ETyBSZW1vdGUgQ29yZSBDb25maWdcbiAgICB0cnkge1xuICAgICAgICAvLyBFbnN1cmUgc2VwZXJhdGUgb2JqZWN0cyBhcmUgY3JlYXRlZCBhcyBDb3JlQ29uZmlnIHdpbGwgYmUgbXV0YXRlZCBpZiB0aGVyZSBhcmVcbiAgICAgICAgLy8gU3RhY2sgQ29uZmlnIHZhbHVlcyB0aGF0IGNoYWdlXG4gICAgICAgIFJlbW90ZUNvcmVDb25maWcgPSBUeXBlVmFsaWRhdG9yLnR5cGUoXG4gICAgICAgICAgICBDb3JlQ29uZmlnVHlwZSxcbiAgICAgICAgICAgIHhtbGpzLnhtbDJqcyhleGlzdGluZ0NvcmVDb25maWcuU2VjcmV0U3RyaW5nLCB7IGNvbXBhY3Q6IHRydWUgfSksXG4gICAgICAgICAgICB7XG4gICAgICAgICAgICAgICAgY2xlYW46IGZhbHNlLFxuICAgICAgICAgICAgICAgIHZlcmJvc2U6IHRydWUsXG4gICAgICAgICAgICAgICAgY29udmVydDogdHJ1ZSxcbiAgICAgICAgICAgICAgICBkZWZhdWx0OiB0cnVlXG4gICAgICAgICAgICB9XG4gICAgICAgICk7XG5cbiAgICAgICAgQ29yZUNvbmZpZyA9IHN0cnVjdHVyZWRDbG9uZShSZW1vdGVDb3JlQ29uZmlnKTtcbiAgICB9IGNhdGNoIChlcnIpIHtcbiAgICAgICAgY29uc29sZS5lcnJvcihlcnIpO1xuICAgIH1cbiovXG5cbmlmICghQ29yZUNvbmZpZykge1xuICAgIENvcmVDb25maWcgPSB7XG4gICAgICAgIENvbmZpZ3VyYXRpb246IHtcbiAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgeG1sbnM6ICdodHRwOi8vYmJuLmNvbS9tYXJ0aS94bWwvY29uZmlnJ1xuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIG5ldHdvcms6IHtcbiAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICBtdWx0aWNhc3RUVEw6IDUsXG4gICAgICAgICAgICAgICAgICAgIHNlcnZlcklkOiByYW5kb21VVUlEKCksXG4gICAgICAgICAgICAgICAgICAgIHZlcnNpb246IHByb2Nlc3MuZW52LlRBS19WRVJTSU9OLFxuICAgICAgICAgICAgICAgICAgICBjbG91ZHdhdGNoRW5hYmxlOiB0cnVlLFxuICAgICAgICAgICAgICAgICAgICBjbG91ZHdhdGNoTmFtZTogcHJvY2Vzcy5lbnYuU3RhY2tOYW1lXG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICBpbnB1dDoge1xuICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgYXV0aDogSW5wdXRDb25maWcuQXV0aCxcbiAgICAgICAgICAgICAgICAgICAgICAgIF9uYW1lOiAnc3Rkc3NsJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIHByb3RvY29sOiAndGxzJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIHBvcnQ6IDgwODksXG4gICAgICAgICAgICAgICAgICAgICAgICBjb3JlVmVyc2lvbjogMlxuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICBjb25uZWN0b3I6IFt7XG4gICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICBwb3J0OiA4NDQzLFxuICAgICAgICAgICAgICAgICAgICAgICAgX25hbWU6ICdodHRwcycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZTogJ0pLUycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZUZpbGU6IGAvb3B0L3Rhay9jZXJ0cy9maWxlcy8ke0xldHNFbmNyeXB0LkRvbWFpbn0vbGV0c2VuY3J5cHQuamtzYCxcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlUGFzczogJ2F0YWthdGFrJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZU5vbkFkbWluVUk6IENvbm5lY3Rvci5FbmFibGVOb25BZG1pblVJODQ0MyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZUFkbWluVUk6IENvbm5lY3Rvci5FbmFibGVBZG1pblVJODQ0MyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZVdlYnRhazogQ29ubmVjdG9yLkVuYWJsZVdlYnRhazg0NDNcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH0sIHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIHBvcnQ6IDg0NDYsXG4gICAgICAgICAgICAgICAgICAgICAgICBjbGllbnRBdXRoOiBmYWxzZSxcbiAgICAgICAgICAgICAgICAgICAgICAgIF9uYW1lOiAnY2VydF9odHRwcycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZTogJ0pLUycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZUZpbGU6IGAvb3B0L3Rhay9jZXJ0cy9maWxlcy8ke0xldHNFbmNyeXB0LkRvbWFpbn0vbGV0c2VuY3J5cHQuamtzYCxcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlUGFzczogJ2F0YWthdGFrJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZU5vbkFkbWluVUk6IENvbm5lY3Rvci5FbmFibGVOb25BZG1pblVJODQ0NixcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZUFkbWluVUk6IENvbm5lY3Rvci5FbmFibGVBZG1pblVJODQ0NixcbiAgICAgICAgICAgICAgICAgICAgICAgIGVuYWJsZVdlYnRhazogQ29ubmVjdG9yLkVuYWJsZVdlYnRhazg0NDZcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1dLFxuICAgICAgICAgICAgICAgIGFubm91bmNlOiB7XG4gICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7fVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBhdXRoOiB7XG4gICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgZGVmYXVsdDogJ2xkYXAnLFxuICAgICAgICAgICAgICAgICAgICB4NTA5Z3JvdXBzOiBMREFQX0F1dGguWDUwOWdyb3VwcyxcbiAgICAgICAgICAgICAgICAgICAgeDUwOWFkZEFub255bW91czogTERBUF9BdXRoLlg1MDlhZGRBbm9ueW1vdXMsXG4gICAgICAgICAgICAgICAgICAgIHg1MDl1c2VHcm91cENhY2hlOiBMREFQX0F1dGguWDUwOXVzZUdyb3VwQ2FjaGUsXG4gICAgICAgICAgICAgICAgICAgIHg1MDl1c2VHcm91cENhY2hlRGVmYXVsdEFjdGl2ZTogTERBUF9BdXRoLlg1MDl1c2VHcm91cENhY2hlRGVmYXVsdEFjdGl2ZSxcbiAgICAgICAgICAgICAgICAgICAgeDUwOWNoZWNrUmV2b2NhdGlvbjogTERBUF9BdXRoLlg1MDljaGVja1Jldm9jYXRpb25cbiAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgIGxkYXA6IHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIHVybDogcHJvY2Vzcy5lbnYuTERBUF9TRUNVUkVfVVJMLFxuICAgICAgICAgICAgICAgICAgICAgICAgdXNlcnN0cmluZzogTERBUF9BdXRoLkxEQVBfVXNlcnN0cmluZyArIHByb2Nlc3MuZW52LkxEQVBfRE4sXG4gICAgICAgICAgICAgICAgICAgICAgICB1cGRhdGVpbnRlcnZhbDogTERBUF9BdXRoLkxEQVBfVXBkYXRlaW50ZXJ2YWwsXG4gICAgICAgICAgICAgICAgICAgICAgICBncm91cHByZWZpeDogTERBUF9BdXRoLkxEQVBfR3JvdXBwcmVmaXgsXG4gICAgICAgICAgICAgICAgICAgICAgICBncm91cE5hbWVFeHRyYWN0b3JSZWdleDogTERBUF9BdXRoLkxEQVBfR3JvdXBOYW1lRXh0cmFjdG9yUmVnZXgsXG4gICAgICAgICAgICAgICAgICAgICAgICBzdHlsZTogTERBUF9BdXRoLkxEQVBfU3R5bGUsXG4gICAgICAgICAgICAgICAgICAgICAgICBzZXJ2aWNlQWNjb3VudEROOiBMREFQX0F1dGguTERBUF9TZXJ2aWNlQWNjb3VudEROICsgcHJvY2Vzcy5lbnYuTERBUF9ETixcbiAgICAgICAgICAgICAgICAgICAgICAgIHNlcnZpY2VBY2NvdW50Q3JlZGVudGlhbDogcHJvY2Vzcy5lbnYuTERBUF9QYXNzd29yZCxcbiAgICAgICAgICAgICAgICAgICAgICAgIHVzZXJPYmplY3RDbGFzczogTERBUF9BdXRoLkxEQVBfVXNlck9iamVjdENsYXNzLFxuICAgICAgICAgICAgICAgICAgICAgICAgZ3JvdXBPYmplY3RDbGFzczogTERBUF9BdXRoLkxEQVBfR3JvdXBPYmplY3RDbGFzcyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGdyb3VwQmFzZVJETjogTERBUF9BdXRoLkxEQVBfR3JvdXBCYXNlUkROICsgcHJvY2Vzcy5lbnYuTERBUF9ETixcbiAgICAgICAgICAgICAgICAgICAgICAgIHVzZXJCYXNlUkROOiBMREFQX0F1dGguTERBUF9Vc2VyQmFzZVJETiArIHByb2Nlc3MuZW52LkxEQVBfRE4sXG4gICAgICAgICAgICAgICAgICAgICAgICBkbkF0dHJpYnV0ZU5hbWU6IExEQVBfQXV0aC5MREFQX0RuQXR0cmlidXRlTmFtZSxcbiAgICAgICAgICAgICAgICAgICAgICAgIG5hbWVBdHRyOiBMREFQX0F1dGguTERBUF9OYW1lQXR0cixcbiAgICAgICAgICAgICAgICAgICAgICAgIG5lc3RlZEdyb3VwTG9va3VwOiBMREFQX0F1dGguTERBUF9OZXN0ZWRHcm91cExvb2t1cCxcbiAgICAgICAgICAgICAgICAgICAgICAgIGNhbGxzaWduQXR0cmlidXRlOiBMREFQX0F1dGguTERBUF9DYWxsc2lnbkF0dHJpYnV0ZSxcbiAgICAgICAgICAgICAgICAgICAgICAgIGNvbG9yQXR0cmlidXRlOiBMREFQX0F1dGguTERBUF9Db2xvckF0dHJpYnV0ZSxcbiAgICAgICAgICAgICAgICAgICAgICAgIHJvbGVBdHRyaWJ1dGU6IExEQVBfQXV0aC5MREFQX1JvbGVBdHRyaWJ1dGUsXG4gICAgICAgICAgICAgICAgICAgICAgICBsZGFwc1RydXN0c3RvcmU6ICdKS1MnLFxuICAgICAgICAgICAgICAgICAgICAgICAgbGRhcHNUcnVzdHN0b3JlRmlsZTogJy9vcHQvdGFrL2NlcnRzL2ZpbGVzL2F3cy1hY20tcm9vdC5qa3MnLFxuICAgICAgICAgICAgICAgICAgICAgICAgbGRhcHNUcnVzdHN0b3JlUGFzczogJ0lOVEVOVElPTkFMTFlfTk9UX1NFTlNJVElWRScsXG4gICAgICAgICAgICAgICAgICAgICAgICBlbmFibGVDb25uZWN0aW9uUG9vbDogZmFsc2VcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICAgLi4uKE9BdXRoLk9BdXRoU2VydmVyTmFtZSAmJiBPQXV0aC5PQXV0aFNlcnZlcklzc3VlciAmJiBPQXV0aC5PQXV0aFNlcnZlckNsaWVudElkICYmIE9BdXRoLk9BdXRoU2VydmVyU2VjcmV0ICYmIE9BdXRoLk9BdXRoU2VydmVyUmVkaXJlY3RVcmkgJiYgT0F1dGguT0F1dGhTZXJ2ZXJBdXRoRW5kcG9pbnQgJiYgT0F1dGguT0F1dGhTZXJ2ZXJUb2tlbkVuZHBvaW50KSAmJiAoe1xuICAgICAgICAgICAgICAgICAgICBvYXV0aDoge1xuICAgICAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguT2F1dGhVc2VHcm91cENhY2hlICYmIHsgb2F1dGhVc2VHcm91cENhY2hlOiBPQXV0aC5PYXV0aFVzZUdyb3VwQ2FjaGUgfSksXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgLi4uKE9BdXRoLkxvZ2luV2l0aEVtYWlsICYmIHsgbG9naW5XaXRoRW1haWw6IE9BdXRoLkxvZ2luV2l0aEVtYWlsIH0pLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIC4uLihPQXV0aC5Vc2VUYWtTZXJ2ZXJMb2dpblBhZ2UgJiYgeyB1c2VUYWtTZXJ2ZXJMb2dpblBhZ2U6IE9BdXRoLlVzZVRha1NlcnZlckxvZ2luUGFnZSB9KSxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguR3JvdXBzQ2xhaW0gJiYgeyBncm91cHNDbGFpbTogT0F1dGguR3JvdXBzQ2xhaW0gfSksXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgLi4uKE9BdXRoLlVzZXJuYW1lQ2xhaW0gJiYgeyB1c2VybmFtZUNsYWltOiBPQXV0aC5Vc2VybmFtZUNsYWltIH0pLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIC4uLihPQXV0aC5TY29wZUNsYWltICYmIHsgc2NvcGVDbGFpbTogT0F1dGguU2NvcGVDbGFpbSB9KSxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguV2VidGFrU2NvcGUgJiYgeyB3ZWJ0YWtTY29wZTogT0F1dGguV2VidGFrU2NvcGUgfSksXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgLi4uKE9BdXRoLkdyb3VwcHJlZml4ICYmIHsgZ3JvdXBwcmVmaXg6IE9BdXRoLkdyb3VwcHJlZml4IH0pLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIC4uLihPQXV0aC5BbGxvd1VyaVF1ZXJ5UGFyYW1ldGVyICYmIHsgYWxsb3dVcmlRdWVyeVBhcmFtZXRlcjogT0F1dGguQWxsb3dVcmlRdWVyeVBhcmFtZXRlciB9KVxuICAgICAgICAgICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICAgICAgICAgIGF1dGhTZXJ2ZXI6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBuYW1lOiBPQXV0aC5PQXV0aFNlcnZlck5hbWUsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlzc3VlcjogT0F1dGguT0F1dGhTZXJ2ZXJJc3N1ZXIsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNsaWVudElkOiBPQXV0aC5PQXV0aFNlcnZlckNsaWVudElkLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWNyZXQ6IE9BdXRoLk9BdXRoU2VydmVyU2VjcmV0LFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICByZWRpcmVjdFVyaTogT0F1dGguT0F1dGhTZXJ2ZXJSZWRpcmVjdFVyaSxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYXV0aEVuZHBvaW50OiBPQXV0aC5PQXV0aFNlcnZlckF1dGhFbmRwb2ludCxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLi4uKE9BdXRoLk9BdXRoU2VydmVyU2NvcGUgJiYgeyBzY29wZTogT0F1dGguT0F1dGhTZXJ2ZXJTY29wZSB9KSxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdG9rZW5FbmRwb2ludDogT0F1dGguT0F1dGhTZXJ2ZXJUb2tlbkVuZHBvaW50LFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguT0F1dGhTZXJ2ZXJBY2Nlc3NUb2tlbk5hbWUgJiYgeyBhY2Nlc3NUb2tlbk5hbWU6IE9BdXRoLk9BdXRoU2VydmVyQWNjZXNzVG9rZW5OYW1lIH0pLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguT0F1dGhTZXJ2ZXJSZWZyZXNoVG9rZW5OYW1lICYmIHsgcmVmcmVzaFRva2VuTmFtZTogT0F1dGguT0F1dGhTZXJ2ZXJSZWZyZXNoVG9rZW5OYW1lIH0pLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAuLi4oT0F1dGguT0F1dGhTZXJ2ZXJUcnVzdEFsbENlcnRzICYmIHsgdHJ1c3RBbGxDZXJ0czogT0F1dGguT0F1dGhTZXJ2ZXJUcnVzdEFsbENlcnRzIH0pXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfSlcbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBzdWJtaXNzaW9uOiB7XG4gICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgaWdub3JlU3RhbGVNZXNzYWdlczogZmFsc2UsXG4gICAgICAgICAgICAgICAgICAgIHZhbGlkYXRlWG1sOiBmYWxzZVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBzdWJzY3JpcHRpb246IHtcbiAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICByZWxvYWRQZXJzaXN0ZW50OiBmYWxzZVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICByZXBvc2l0b3J5OiB7XG4gICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgZW5hYmxlOiB0cnVlLFxuICAgICAgICAgICAgICAgICAgICBudW1EYkNvbm5lY3Rpb25zOiAxNixcbiAgICAgICAgICAgICAgICAgICAgcHJpbWFyeUtleUJhdGNoU2l6ZTogNTAwLFxuICAgICAgICAgICAgICAgICAgICBpbnNlcnRpb25CYXRjaFNpemU6IDUwMFxuICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICAgY29ubmVjdGlvbjoge1xuICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgdXJsOiBgamRiYzoke3Byb2Nlc3MuZW52LlBvc3RncmVzVVJMfWAsXG4gICAgICAgICAgICAgICAgICAgICAgICB1c2VybmFtZTogcHJvY2Vzcy5lbnYuUG9zdGdyZXNVc2VybmFtZSxcbiAgICAgICAgICAgICAgICAgICAgICAgIHBhc3N3b3JkOiBwcm9jZXNzLmVudi5Qb3N0Z3Jlc1Bhc3N3b3JkXG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgcmVwZWF0ZXI6IHtcbiAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICBlbmFibGU6IHRydWUsXG4gICAgICAgICAgICAgICAgICAgIHBlcmlvZE1pbGxpczogMzAwMCxcbiAgICAgICAgICAgICAgICAgICAgc3RhbGVEZWxheU1pbGxpczogMTUwMDBcbiAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgIHJlcGVhdGFibGVUeXBlOiBbe1xuICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgJ2luaXRpYXRlLXRlc3QnOiBcIi9ldmVudC9kZXRhaWwvZW1lcmdlbmN5W0B0eXBlPSc5MTEgQWxlcnQnXVwiLFxuICAgICAgICAgICAgICAgICAgICAgICAgJ2NhbmNlbC10ZXN0JzogXCIvZXZlbnQvZGV0YWlsL2VtZXJnZW5jeVtAY2FuY2VsPSd0cnVlJ11cIixcbiAgICAgICAgICAgICAgICAgICAgICAgIF9uYW1lOiAnOTExJ1xuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfSx7XG4gICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICAnaW5pdGlhdGUtdGVzdCc6IFwiL2V2ZW50L2RldGFpbC9lbWVyZ2VuY3lbQHR5cGU9J1JpbmcgVGhlIEJlbGwnXVwiLFxuICAgICAgICAgICAgICAgICAgICAgICAgJ2NhbmNlbC10ZXN0JzogXCIvZXZlbnQvZGV0YWlsL2VtZXJnZW5jeVtAY2FuY2VsPSd0cnVlJ11cIixcbiAgICAgICAgICAgICAgICAgICAgICAgIF9uYW1lOiAnUmluZ1RoZUJlbGwnXG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9LHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgICdpbml0aWF0ZS10ZXN0JzogXCIvZXZlbnQvZGV0YWlsL2VtZXJnZW5jeVtAdHlwZT0nR2VvLWZlbmNlIEJyZWFjaGVkJ11cIixcbiAgICAgICAgICAgICAgICAgICAgICAgICdjYW5jZWwtdGVzdCc6IFwiL2V2ZW50L2RldGFpbC9lbWVyZ2VuY3lbQGNhbmNlbD0ndHJ1ZSddXCIsXG4gICAgICAgICAgICAgICAgICAgICAgICBfbmFtZTogJ0dlb0ZlbmNlQnJlYWNoJ1xuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfSx7XG4gICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICAnaW5pdGlhdGUtdGVzdCc6IFwiL2V2ZW50L2RldGFpbC9lbWVyZ2VuY3lbQHR5cGU9J1Ryb29wcyBJbiBDb250YWN0J11cIixcbiAgICAgICAgICAgICAgICAgICAgICAgICdjYW5jZWwtdGVzdCc6IFwiL2V2ZW50L2RldGFpbC9lbWVyZ2VuY3lbQGNhbmNlbD0ndHJ1ZSddXCIsXG4gICAgICAgICAgICAgICAgICAgICAgICBfbmFtZTogJ1Ryb29wc0luQ29udGFjdCdcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1dXG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgZmlsdGVyOiB7XG4gICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHt9XG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgYnVmZmVyOiB7XG4gICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHt9LFxuICAgICAgICAgICAgICAgIHF1ZXVlOiB7XG4gICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7fSxcbiAgICAgICAgICAgICAgICAgICAgcHJpb3JpdHk6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7fVxuICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICBsYXRlc3RTQToge1xuICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgZW5hYmxlOiB0cnVlXG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgZGlzc2VtaW5hdGlvbjoge1xuICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgIHNtYXJ0UmV0cnk6IGZhbHNlXG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIGNlcnRpZmljYXRlU2lnbmluZzoge1xuICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgIENBOiAnVEFLU2VydmVyJ1xuICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICAgY2VydGlmaWNhdGVDb25maWc6IHtcbiAgICAgICAgICAgICAgICAgICAgbmFtZUVudHJpZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIG5hbWVFbnRyeTogW3tcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBuYW1lOiAnTycsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBDZXJ0aWZpY2F0ZS5PXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICAgICAgfSx7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgbmFtZTogJ09VJyxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU6IENlcnRpZmljYXRlLk9VXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICAgICAgfV1cbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH0sXG4gICAgICAgICAgICAgICAgVEFLU2VydmVyQ0FDb25maWc6IHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlOiAnSktTJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlRmlsZTogJy9vcHQvdGFrL2NlcnRzL2ZpbGVzL2ludGVybWVkaWF0ZS1jYS1zaWduaW5nLmprcycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZVBhc3M6ICdhdGFrYXRhaycsXG4gICAgICAgICAgICAgICAgICAgICAgICB2YWxpZGl0eURheXM6ICczNjUnLFxuICAgICAgICAgICAgICAgICAgICAgICAgc2lnbmF0dXJlQWxnOiAnU0hBMjU2V2l0aFJTQScsXG4gICAgICAgICAgICAgICAgICAgICAgICBDQWtleTogJy9vcHQvdGFrL2NlcnRzL2ZpbGVzL2ludGVybWVkaWF0ZS1jYS1zaWduaW5nJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIENBY2VydGlmaWNhdGU6ICcvb3B0L3Rhay9jZXJ0cy9maWxlcy9pbnRlcm1lZGlhdGUtY2Etc2lnbmluZydcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBzZWN1cml0eToge1xuICAgICAgICAgICAgICAgIHRsczoge1xuICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAga2V5c3RvcmU6ICdKS1MnLFxuICAgICAgICAgICAgICAgICAgICAgICAga2V5c3RvcmVGaWxlOiAnL29wdC90YWsvY2VydHMvZmlsZXMvdGFrc2VydmVyLmprcycsXG4gICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZVBhc3M6ICdhdGFrYXRhaycsXG4gICAgICAgICAgICAgICAgICAgICAgICB0cnVzdHN0b3JlOiAnSktTJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIHRydXN0c3RvcmVGaWxlOiAnL29wdC90YWsvY2VydHMvZmlsZXMvdHJ1c3RzdG9yZS1pbnRlcm1lZGlhdGUtY2EuamtzJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIHRydXN0c3RvcmVQYXNzOiAnYXRha2F0YWsnLFxuICAgICAgICAgICAgICAgICAgICAgICAgY29udGV4dDogJ1RMU3YxLjInLFxuICAgICAgICAgICAgICAgICAgICAgICAga2V5bWFuYWdlcjogJ1N1blg1MDknXG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgIG1pc3Npb25UbHM6IHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlOiAnSktTJyxcbiAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlRmlsZTogJy9vcHQvdGFrL2NlcnRzL2ZpbGVzL3RydXN0c3RvcmUtcm9vdC5qa3MnLFxuICAgICAgICAgICAgICAgICAgICAgICAga2V5c3RvcmVQYXNzOiAnYXRha2F0YWsnXG4gICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgZmVkZXJhdGlvbjoge1xuICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgIGFsbG93RmVkZXJhdGVkRGVsZXRlOiBGZWRlcmF0aW9uLkFsbG93RmVkZXJhdGVkRGVsZXRlLFxuICAgICAgICAgICAgICAgICAgICBhbGxvd01pc3Npb25GZWRlcmF0aW9uOiBGZWRlcmF0aW9uLkFsbG93TWlzc2lvbkZlZGVyYXRpb24sXG4gICAgICAgICAgICAgICAgICAgIGFsbG93RGF0YUZlZWRGZWRlcmF0aW9uOiBGZWRlcmF0aW9uLkFsbG93RGF0YUZlZWRGZWRlcmF0aW9uLFxuICAgICAgICAgICAgICAgICAgICBlbmFibGVNaXNzaW9uRmVkZXJhdGlvbkRpc3J1cHRpb25Ub2xlcmFuY2U6IEZlZGVyYXRpb24uRW5hYmxlTWlzc2lvbkZlZGVyYXRpb25EaXNydXB0aW9uVG9sZXJhbmNlLFxuICAgICAgICAgICAgICAgICAgICBtaXNzaW9uRmVkZXJhdGlvbkRpc3J1cHRpb25Ub2xlcmFuY2VSZWNlbmN5U2Vjb25kczogRmVkZXJhdGlvbi5NaXNzaW9uRmVkZXJhdGlvbkRpc3J1cHRpb25Ub2xlcmFuY2VSZWNlbmN5U2Vjb25kcyxcbiAgICAgICAgICAgICAgICAgICAgZW5hYmxlRmVkZXJhdGlvbjogRmVkZXJhdGlvbi5FbmFibGVGZWRlcmF0aW9uLFxuICAgICAgICAgICAgICAgICAgICBlbmFibGVEYXRhUGFja2FnZUFuZE1pc3Npb25GaWxlRmlsdGVyOiBGZWRlcmF0aW9uLkVuYWJsZURhdGFQYWNrYWdlQW5kTWlzc2lvbkZpbGVGaWx0ZXJcbiAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgICdmZWRlcmF0aW9uLXNlcnZlcic6IHtcbiAgICAgICAgICAgICAgICAgICAgX2F0dHJpYnV0ZXM6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIHBvcnQ6IDkwMDAsXG4gICAgICAgICAgICAgICAgICAgICAgICBjb3JlVmVyc2lvbjogMixcbiAgICAgICAgICAgICAgICAgICAgICAgIHYxZW5hYmxlZDogZmFsc2UsXG4gICAgICAgICAgICAgICAgICAgICAgICB2MnBvcnQ6IDkwMDEsXG4gICAgICAgICAgICAgICAgICAgICAgICB2MmVuYWJsZWQ6IHRydWUsXG4gICAgICAgICAgICAgICAgICAgICAgICB3ZWJCYXNlVXJsOiBGZWRlcmF0aW9uLkZlZGVyYXRpb25fV2ViQmFzZVVybCxcbiAgICAgICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICAgICAgdGxzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleXN0b3JlOiAnSktTJyxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZUZpbGU6ICcvb3B0L3Rhay9jZXJ0cy9maWxlcy90YWtzZXJ2ZXIuamtzJyxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXlzdG9yZVBhc3M6ICdhdGFrYXRhaycsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgdHJ1c3RzdG9yZTogJ0pLUycsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgdHJ1c3RzdG9yZUZpbGU6ICcvb3B0L3Rhay9jZXJ0cy9maWxlcy9mZWQtdHJ1c3RzdG9yZS5qa3MnLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIHRydXN0c3RvcmVQYXNzOiAnYXRha2F0YWsnLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbnRleHQ6ICdUTFN2MS4yJyxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXltYW5hZ2VyOiAnU3VuWDUwOSdcbiAgICAgICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICAgICAgJ2ZlZGVyYXRpb24tcG9ydCc6IHtcbiAgICAgICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgcG9ydDogOTAwMCxcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICB0bHNWZXJzaW9uOiAnVExTdjEuMidcbiAgICAgICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICAgICAgdjFUbHM6IFt7XG4gICAgICAgICAgICAgICAgICAgICAgICBfYXR0cmlidXRlczoge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIHRsc1ZlcnNpb246ICdUTFN2MS4yJ1xuICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICB9LHtcbiAgICAgICAgICAgICAgICAgICAgICAgIF9hdHRyaWJ1dGVzOiB7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgdGxzVmVyc2lvbjogJ1RMU3YxLjMnXG4gICAgICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICAgIH1dXG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICBmaWxlRmlsdGVyOiB7XG4gICAgICAgICAgICAgICAgICAgIGZpbGVFeHRlbnNpb246IFsncHJlZiddXG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIHBsdWdpbnM6IHt9LFxuICAgICAgICAgICAgY2x1c3Rlcjoge30sXG4gICAgICAgICAgICB2Ym06IHt9XG4gICAgICAgIH1cbiAgICB9O1xufVxuXG5pZiAoQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLm5ldHdvcmsuY29ubmVjdG9yKSB7XG4gICAgaWYgKCFBcnJheS5pc0FycmF5KENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5uZXR3b3JrLmNvbm5lY3RvcikpIHtcbiAgICAgICAgQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLm5ldHdvcmsuY29ubmVjdG9yID0gWyBDb3JlQ29uZmlnLkNvbmZpZ3VyYXRpb24ubmV0d29yay5jb25uZWN0b3JdO1xuICAgIH1cblxuICAgIGZvciAoY29uc3QgY29ubmVjdG9yIG9mIENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5uZXR3b3JrLmNvbm5lY3Rvcikge1xuICAgICAgICBpZiAoY29ubmVjdG9yLl9hdHRyaWJ1dGVzLmtleXN0b3JlRmlsZSAmJiBjb25uZWN0b3IuX2F0dHJpYnV0ZXMua2V5c3RvcmVQYXNzKSB7XG4gICAgICAgICAgICB2YWxpZGF0ZUtleXN0b3JlKGNvbm5lY3Rvci5fYXR0cmlidXRlcy5rZXlzdG9yZUZpbGUsIGNvbm5lY3Rvci5fYXR0cmlidXRlcy5rZXlzdG9yZVBhc3MpO1xuICAgICAgICB9XG4gICAgfVxufSBlbHNlIHtcbiAgICBjb25zb2xlLndhcm4oJ05vIE5ldHdvcmsgQ29ubmVjdG9ycyBGb3VuZCcpO1xufVxuXG5pZiAoQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLmNlcnRpZmljYXRlU2lnbmluZy5UQUtTZXJ2ZXJDQUNvbmZpZykge1xuICAgIHZhbGlkYXRlS2V5c3RvcmUoXG4gICAgICAgIENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5jZXJ0aWZpY2F0ZVNpZ25pbmcuVEFLU2VydmVyQ0FDb25maWcuX2F0dHJpYnV0ZXMua2V5c3RvcmVGaWxlLFxuICAgICAgICBDb3JlQ29uZmlnLkNvbmZpZ3VyYXRpb24uY2VydGlmaWNhdGVTaWduaW5nLlRBS1NlcnZlckNBQ29uZmlnLl9hdHRyaWJ1dGVzLmtleXN0b3JlUGFzc1xuICAgICk7XG59XG5cbmlmIChDb3JlQ29uZmlnLkNvbmZpZ3VyYXRpb24uYXV0aC5sZGFwKSB7XG4gICAgdmFsaWRhdGVLZXlzdG9yZShcbiAgICAgICAgQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLmF1dGgubGRhcC5fYXR0cmlidXRlcy5sZGFwc1RydXN0c3RvcmVGaWxlLFxuICAgICAgICBDb3JlQ29uZmlnLkNvbmZpZ3VyYXRpb24uYXV0aC5sZGFwLl9hdHRyaWJ1dGVzLmxkYXBzVHJ1c3RzdG9yZVBhc3NcbiAgICApO1xufVxuXG5pZiAoQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLnNlY3VyaXR5KSB7XG4gICAgaWYgKENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5zZWN1cml0eS50bHMpIHtcbiAgICAgICAgdmFsaWRhdGVLZXlzdG9yZShcbiAgICAgICAgICAgIENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5zZWN1cml0eS50bHMuX2F0dHJpYnV0ZXMua2V5c3RvcmVGaWxlLFxuICAgICAgICAgICAgQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLnNlY3VyaXR5LnRscy5fYXR0cmlidXRlcy5rZXlzdG9yZVBhc3NcbiAgICAgICAgKTtcbiAgICB9XG5cbiAgICBpZiAoQ29yZUNvbmZpZy5Db25maWd1cmF0aW9uLnNlY3VyaXR5Lm1pc3Npb25UbHMpIHtcbiAgICAgICAgdmFsaWRhdGVLZXlzdG9yZShcbiAgICAgICAgICAgIENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5zZWN1cml0eS5taXNzaW9uVGxzLl9hdHRyaWJ1dGVzLmtleXN0b3JlRmlsZSxcbiAgICAgICAgICAgIENvcmVDb25maWcuQ29uZmlndXJhdGlvbi5zZWN1cml0eS5taXNzaW9uVGxzLl9hdHRyaWJ1dGVzLmtleXN0b3JlUGFzc1xuICAgICAgICApO1xuICAgIH1cbn1cblxuY29uc3QgeG1sID0geG1sanMuanMyeG1sKENvcmVDb25maWcsIHtcbiAgICBzcGFjZXM6IDQsXG4gICAgY29tcGFjdDogdHJ1ZVxufSk7XG5cbmZzLndyaXRlRmlsZVN5bmMoXG4gICAgJy9vcHQvdGFrL0NvcmVDb25maWcueG1sJyxcbiAgICBgPD94bWwgdmVyc2lvbj1cIjEuMFwiIGVuY29kaW5nPVwiVVRGLThcIiBzdGFuZGFsb25lPVwieWVzXCI/PlxcbiR7eG1sfWBcbik7XG5cbnRyeSB7XG4gICAgY29uc29sZS5sb2coJ29rIC0gVEFLIFNlcnZlciAtIENoZWNraW5nIGZvciBEaWZmIGluIENvcmVDb25maWcueG1sJyk7XG4gICAgY29uc3QgZGlmZnMgPSBkaWZmKFJlbW90ZUNvcmVDb25maWcsIENvcmVDb25maWcpO1xuXG4gICAgaWYgKGRpZmZzLmxlbmd0aCA+IDApIHtcbiAgICAgICAgY29uc29sZS5sb2coJ29rIC0gVEFLIFNlcnZlciAtIENvcmVDb25maWcueG1sIGNoYW5nZSBkZXRlY3RlZCcpO1xuICAgIH0gZWxzZSB7XG4gICAgICAgIGNvbnNvbGUubG9nKCdvayAtIFRBSyBTZXJ2ZXIgLSBObyBDb3JlQ29uZmlnLnhtbCBjaGFuZ2UgZGV0ZWN0ZWQnKTtcbiAgICB9XG59IGNhdGNoIChlcnIpIHtcbiAgICBjb25zb2xlLmVycm9yKGVycik7XG59XG5cbmZ1bmN0aW9uIHZhbGlkYXRlS2V5c3RvcmUoZmlsZSwgcGFzcykge1xuICAgIGZzLmFjY2Vzc1N5bmMoZmlsZSk7XG4gICAgY29uc3QgamtzQnVmZmVyID0gZnMucmVhZEZpbGVTeW5jKGZpbGUpO1xuICAgIHRvUGVtKGprc0J1ZmZlciwgcGFzcyk7XG59XG5cbmZ1bmN0aW9uIHN0cmluZ1RvQm9vbGVhbihzdHI6IHN0cmluZyk6IGJvb2xlYW4ge1xuICAgIHJldHVybiBzdHIudG9Mb3dlckNhc2UoKSA9PT0gJ3RydWUnO1xufSJdfQ==