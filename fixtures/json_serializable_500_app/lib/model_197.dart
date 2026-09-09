import 'package:json_annotation/json_annotation.dart';

part 'model_197.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model197 {
  const Model197({required this.id, required this.value});

  final int id;
  final String value;

  factory Model197.fromJson(Map<String, dynamic> json) =>
      _$Model197FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model197ToJson(this);
}
