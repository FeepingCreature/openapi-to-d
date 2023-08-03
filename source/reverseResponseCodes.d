module reverseResponseCodes;

// Returns a net.http.ResponseCode member for a given response code.
string codeToMember(string code)
{
    switch (code)
    {
        case "100": return "continue";
        case "101": return "switchingProtocols";
        case "200": return "ok";
        case "201": return "created";
        case "202": return "accepted";
        case "203": return "nonAuthoritativeInformation";
        case "204": return "noContent";
        case "205": return "resetContent";
        case "206": return "partialContent";
        case "207": return "multiStatus";
        case "300": return "multipleChoices";
        case "301": return "movedPermanently";
        case "302": return "found";
        case "303": return "seeOther";
        case "304": return "notModified";
        case "305": return "useProxy";
        case "307": return "temporaryRedirect";
        case "400": return "badRequest";
        case "401": return "unauthorized";
        case "402": return "paymentRequired";
        case "403": return "forbidden";
        case "404": return "notFound";
        case "405": return "methodNotAllowed";
        case "406": return "notAcceptable";
        case "407": return "proxyAuthenticationRequired";
        case "408": return "requestTimeout";
        case "409": return "conflict";
        case "410": return "gone";
        case "411": return "lengthRequired";
        case "412": return "preconditionFailed";
        case "413": return "requestEntityTooLarge";
        case "414": return "requestUriTooLong";
        case "415": return "unsupportedMediaType";
        case "416": return "requestedRangeNotSatisfiable";
        case "417": return "expectationFailed";
        case "418": return "imATeapot";
        case "422": return "unprocessableEntity";
        case "423": return "locked";
        case "424": return "failedDependency";
        case "500": return "internalServerError";
        case "501": return "notImplemented";
        case "502": return "badGateway";
        case "503": return "serviceUnavailable";
        case "504": return "gatewayTimeout";
        case "505": return "httpVersionNotSupported";
        case "507": return "insufficientStorage";
        case "512": return "concurrentModification";
        default: return null;
    }
}
