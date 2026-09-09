import 'package:json_annotation/json_annotation.dart';

part 'model_090.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model090 {
  const Model090({required this.id, required this.value});

  final int id;
  final String value;

  factory Model090.fromJson(Map<String, dynamic> json) =>
      _$Model090FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model090ToJson(this);
}
