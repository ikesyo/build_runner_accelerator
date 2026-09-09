import 'package:json_annotation/json_annotation.dart';

part 'model_192.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model192 {
  const Model192({required this.id, required this.value});

  final int id;
  final String value;

  factory Model192.fromJson(Map<String, dynamic> json) =>
      _$Model192FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model192ToJson(this);
}
