import 'package:oauth2_client/access_token_response.dart';
import 'package:oauth2_client/oauth2_exception.dart';
import 'package:oauth2_client/oauth2_client.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:oauth2_client/oauth2_response.dart';
import 'package:oauth2_client/src/token_storage.dart';

/// Helper class for simplifying OAuth2 authorization process.
///
/// Tokens are stored in a secure storage.
/// The helper performs automatic token refreshing upon access token expiration.
/// Moreover it provides methods to perform http post/get calls with automatic Access Token injection in the requests header
///
///
class OAuth2Helper extends http.BaseClient {
  static const AUTHORIZATION_CODE = 1;
  static const CLIENT_CREDENTIALS = 2;
  static const IMPLICIT_GRANT = 3;

  final OAuth2Client client;
  TokenStorage tokenStorage;

  int grantType;
  String clientId;
  String clientSecret;
  List<String> scopes;
  bool enablePKCE;
  bool enableState;

  Function afterAuthorizationCodeCb;

  Map<String, dynamic> authCodeParams;
  Map<String, dynamic> accessTokenParams;
  http.Client httpClient = http.Client();

  OAuth2Helper(
    this.client, {
    this.grantType = AUTHORIZATION_CODE,
    this.clientId,
    this.clientSecret,
    this.scopes,
    this.enablePKCE = true,
    this.enableState = true,
    this.tokenStorage,
    this.afterAuthorizationCodeCb,
    this.authCodeParams,
    this.accessTokenParams,
    this.httpClient,
  }) {
    tokenStorage ??= TokenStorage(client.tokenUrl);
    httpClient ??= http.Client();
  }

  /// Sets the proper parameters for requesting an authorization token.
  ///
  /// The parameters are validated depending on the [grantType].
  void setAuthorizationParams(
      {@required int grantType,
      String clientId,
      String clientSecret,
      List<String> scopes,
      bool enablePKCE,
      bool enableState,
      Map<String, dynamic> authCodeParams,
      Map<String, dynamic> accessTokenParams}) {
    this.grantType = grantType;
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.scopes = scopes;
    this.enablePKCE = enablePKCE ?? true;
    this.enableState = enableState ?? true;
    this.authCodeParams = authCodeParams;
    this.accessTokenParams = accessTokenParams;

    _validateAuthorizationParams();
  }

  /// Returns a previously required token, if any, or requires a new one.
  ///
  /// If a token already exists but is expired, a new token is generated through the refresh_token grant.
  Future<AccessTokenResponse> getToken() async {
    _validateAuthorizationParams();

    var tknResp = await getTokenFromStorage();

    if (tknResp != null) {
      if (tknResp.refreshNeeded()) {
        //The access token is expired
        tknResp = await refreshToken(tknResp.refreshToken);
      }
    } else {
      tknResp = await fetchToken();
    }

    if (tknResp != null && !tknResp.isBearer()) {
      throw Exception('Only Bearer tokens are currently supported');
    }

    return tknResp;
  }

  /// Returns the previously stored Access Token from the storage, if any
  Future<AccessTokenResponse> getTokenFromStorage() async {
    return await tokenStorage.getToken(scopes);
  }

  /// Fetches a new token and saves it in the storage
  Future<AccessTokenResponse> fetchToken() async {
    _validateAuthorizationParams();

    AccessTokenResponse tknResp;

    if (grantType == AUTHORIZATION_CODE) {
      tknResp = await client.getTokenWithAuthCodeFlow(
          clientId: clientId,
          clientSecret: clientSecret,
          scopes: scopes,
          enablePKCE: enablePKCE ?? true,
          enableState: enableState ?? true,
          authCodeParams: authCodeParams,
          accessTokenParams: accessTokenParams,
          afterAuthorizationCodeCb: afterAuthorizationCodeCb);
    } else if (grantType == CLIENT_CREDENTIALS) {
      tknResp = await client.getTokenWithClientCredentialsFlow(
          clientId: clientId, clientSecret: clientSecret, scopes: scopes);
    } else if (grantType == IMPLICIT_GRANT) {
      tknResp = await client.getTokenWithImplicitGrantFlow(
        clientId: clientId,
        scopes: scopes,
        enableState: enableState ?? true,
      );
    }

    if (tknResp != null && tknResp.isValid()) {
      await tokenStorage.addToken(tknResp);
    }

    return tknResp;
  }

  /// Performs a refresh_token request using the [refreshToken].
  Future<AccessTokenResponse> refreshToken(String refreshToken) async {
    var tknResp;

    try {
      tknResp = await client.refreshToken(refreshToken,
          clientId: clientId, clientSecret: clientSecret);
    } catch (_) {
      return await fetchToken();
    }

    if (tknResp == null) {
      throw OAuth2Exception('Unexpected error');
    } else if (tknResp.isValid()) {
      //If the response doesn't contain a refresh token, keep using the current one
      if (!tknResp.hasRefreshToken()) {
        tknResp.refreshToken = refreshToken;
      }
      await tokenStorage.addToken(tknResp);
    } else {
      if (tknResp.error == 'invalid_grant') {
        //The refresh token is expired too
        await tokenStorage.deleteToken(scopes);
        //Fetch another access token
        tknResp = await getToken();
      } else {
        throw OAuth2Exception(tknResp.error,
            errorDescription: tknResp.errorDescription);
      }
    }

    return tknResp;
  }

  /// Revokes the previously fetched token
  Future<OAuth2Response> disconnect({httpClient}) async {
    httpClient ??= http.Client();

    final tknResp = await tokenStorage.getToken(scopes);

    if (tknResp != null) {
      await tokenStorage.deleteToken(scopes);
      return await client.revokeToken(tknResp,
          clientId: clientId,
          clientSecret: clientSecret,
          httpClient: httpClient);
    } else {
      return OAuth2Response();
    }
  }

  void _validateAuthorizationParams() {
    switch (grantType) {
      case AUTHORIZATION_CODE:
        if (clientId == null || clientId.isEmpty) {
          throw Exception('Required "clientId" parameter not set');
        }
        break;

      case CLIENT_CREDENTIALS:
        if (clientSecret == null || clientSecret.isEmpty) {
          throw Exception('Required "clientSecret" parameter not set');
        }
        if (clientId == null || clientId.isEmpty) {
          throw Exception('Required "clientId" parameter not set');
        }
        break;

      case IMPLICIT_GRANT:
        if (clientId == null || clientId.isEmpty) {
          throw Exception('Required "clientId" parameter not set');
        }
        break;
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var tokenResponse = await getToken();

    request.headers['Authorization'] = 'Bearer ' + tokenResponse.accessToken;
    var httpResponse = await httpClient.send(request);

    if (httpResponse.statusCode == 401) {
      if (tokenResponse.hasRefreshToken()) {
        tokenResponse = await refreshToken(tokenResponse.refreshToken);
      } else {
        tokenResponse = await fetchToken();
      }

      if (tokenResponse != null && request is http.Request) {
        final clone = http.Request(request.method, request.url);
        clone.body = request.body;
        clone.headers.addAll(request.headers);
        clone.headers['Authorization'] = 'Bearer ' + tokenResponse.accessToken;
        clone.encoding = request.encoding;

        httpResponse = await httpClient.send(request);
      }
    }

    return httpResponse;
  }
}
