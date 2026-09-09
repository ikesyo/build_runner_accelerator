import 'package:json_annotation/json_annotation.dart';

part 'model_138.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model138 {
  const Model138({required this.id, required this.value});

  final int id;
  final String value;

  factory Model138.fromJson(Map<String, dynamic> json) =>
      _$Model138FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model138ToJson(this);
}
