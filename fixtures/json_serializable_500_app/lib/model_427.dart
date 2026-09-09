import 'package:json_annotation/json_annotation.dart';

part 'model_427.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model427 {
  const Model427({required this.id, required this.value});

  final int id;
  final String value;

  factory Model427.fromJson(Map<String, dynamic> json) =>
      _$Model427FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model427ToJson(this);
}
