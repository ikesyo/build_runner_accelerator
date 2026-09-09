import 'package:json_annotation/json_annotation.dart';

part 'model_471.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model471 {
  const Model471({required this.id, required this.value});

  final int id;
  final String value;

  factory Model471.fromJson(Map<String, dynamic> json) =>
      _$Model471FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model471ToJson(this);
}
