import 'package:json_annotation/json_annotation.dart';

part 'model_400.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model400 {
  const Model400({required this.id, required this.value});

  final int id;
  final String value;

  factory Model400.fromJson(Map<String, dynamic> json) =>
      _$Model400FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model400ToJson(this);
}
