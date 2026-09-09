import 'package:json_annotation/json_annotation.dart';

part 'model_333.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model333 {
  const Model333({required this.id, required this.value});

  final int id;
  final String value;

  factory Model333.fromJson(Map<String, dynamic> json) =>
      _$Model333FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model333ToJson(this);
}
