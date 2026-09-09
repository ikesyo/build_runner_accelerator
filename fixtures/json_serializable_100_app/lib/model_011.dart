import 'package:json_annotation/json_annotation.dart';

part 'model_011.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model011 {
  const Model011({required this.id, required this.value});

  final int id;
  final String value;

  factory Model011.fromJson(Map<String, dynamic> json) =>
      _$Model011FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model011ToJson(this);
}
