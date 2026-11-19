import 'package:http/http.dart' as http;

import 'api_transport_stub.dart'
    if (dart.library.js_interop) 'api_transport_web.dart' as platform;

http.Client createApiClient() => platform.createApiClient();
