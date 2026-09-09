import 'package:json_annotation/json_annotation.dart';

part 'model_353.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model353 {
  const Model353({required this.id, required this.value});

  final int id;
  final String value;

  factory Model353.fromJson(Map<String, dynamic> json) =>
      _$Model353FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model353ToJson(this);
}
