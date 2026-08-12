import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

Future<List<String>> fetchOpenCollectiveContributors() async {
  final Uri url = Uri.parse('https://api.opencollective.com/graphql/v2');
  const headers = {'Content-Type': 'application/json'};
  const body =
      '{"query":"query account(\$slug:String){account(slug:\$slug){name slug transactions(type:CREDIT){totalCount nodes{type fromAccount{name}amount{value}}}}}","variables":{"slug":"chameleon-ultra-gui"}}';
  try {
    final response = await http.post(url, headers: headers, body: body);
    final json = jsonDecode(response.body);
    Map<String, int> contributors = {};
    List<String> contributorsList = [];

    for (var node in json["data"]["account"]["transactions"]["nodes"]) {
      contributors[node["fromAccount"]["name"]] =
          (contributors[node["fromAccount"]["name"]] ?? 0) +
              (node["amount"]["value"] as int);
    }

    List<MapEntry<String, int>> sortedEntries = contributors.entries.toList();

    sortedEntries.sort((a, b) => b.value.compareTo(a.value));

    Map.fromEntries(sortedEntries).forEach((key, value) {
      contributorsList.add("$key ($value\$)");
    });

    return contributorsList;
  } catch (e) {
    List<String> error = [kDebugMode ? e.toString() : ''];
    return error;
  }
}
